defmodule Vector.Games.GameServer do
  @moduledoc """
  GenServer managing in-memory state for one active game session.

  Time control rules (enforced server-side, not trusting client):
    - Each move has a per-game time limit (Chess 8 min, Morris 3 min).
      The clock resets to the full limit at the start of every turn.
    - A move-timeout does NOT lose the game: the turn is skipped (passed to
      the opponent) and the timed-out player accrues a "missed turn".
    - If a player misses 2 of their own consecutive turns while the opponent
      is still moving (opponent has 0 misses), the opponent wins (reason "afk").
    - If BOTH players reach 2 missed turns, the game ends as a mutual-AFK
      draw (reason "mutual_afk").
    - A real move resets only the mover's own missed-turn counter to 0.
    - If a player disconnects and does not reconnect within 3 minutes,
      they forfeit (unless the game is already over).

  Edge cases handled:
    - Wrong-turn submissions → rejected
    - Illegal moves → rejected (server validates via MoveValidator)
    - Double-move race: GenServer serialises all calls, so only one
      `make_move` runs at a time
    - Self-play manipulation: colour assigned at session creation, not client
    - Game-over submissions: rejected once `finished` flag is set
    - GenServer idle fallback: if nothing happens for 15 min the process
      stops and the session is marked abandoned
  """
  use GenServer, restart: :transient
  require Logger

  alias Vector.Games
  alias Vector.Games.Chess.MoveValidator,  as: ChessValidator
  alias Vector.Games.Morris.MoveValidator, as: MorrisValidator

  # ── Constants ──────────────────────────────────────────────────────────────

  @disconnect_grace_ms  3 * 60 * 1_000   # 3-min reconnect window
  @idle_stop_ms        15 * 60 * 1_000   # kill idle GenServer after 15 min
  @afk_forfeit_misses  2                 # missed own turns before AFK forfeit/draw

  # Per-move time limit by game type. The clock resets at the start of each turn.
  defp move_limit_ms("chess"),  do: 8 * 60 * 1_000
  defp move_limit_ms("morris"), do: 3 * 60 * 1_000

  # ── Public API ─────────────────────────────────────────────────────────────

  def start_link(session_id),
    do: GenServer.start_link(__MODULE__, session_id, name: via(session_id))

  def get_state(session_id),
    do: GenServer.call(via(session_id), :get_state)

  def make_move(session_id, player_id, move),
    do: GenServer.call(via(session_id), {:make_move, player_id, move})

  def player_connected(session_id, player_id),
    do: GenServer.cast(via(session_id), {:player_connected, player_id})

  def player_disconnected(session_id, player_id),
    do: GenServer.cast(via(session_id), {:player_disconnected, player_id})

  def resign(session_id, player_id),
    do: GenServer.call(via(session_id), {:resign, player_id})

  def via(session_id),
    do: {:via, Registry, {Vector.GameRegistry, session_id}}

  # ── Init ──────────────────────────────────────────────────────────────────

  @impl true
  def init(session_id) do
    session = Games.get_session!(session_id)

    state = %{
      session_id: session_id,
      game_type: session.game_type,
      player_one_id: session.player_one_id,   # always white
      player_two_id: session.player_two_id,   # always black
      game_state: session.state,
      # Per-move time tracking (clock resets to the limit each turn)
      turn_started_at: DateTime.utc_now(),
      move_timer_ref: nil,
      # Consecutive missed turns per colour (reset by that colour's real move)
      missed_turns: %{"white" => 0, "black" => 0},
      # Connection
      connected_players: MapSet.new(),
      disconnect_timers: %{},
      session: session,
      finished: false,
    }

    # White moves first — start the per-move clock now
    state = schedule_move_timer(state, "white")
    {:ok, state, @idle_stop_ms}
  end

  # ── Synchronous calls ──────────────────────────────────────────────────────

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, Map.put(state, :timing, compute_live_timing(state))}, state, @idle_stop_ms}
  end

  @impl true
  def handle_call({:make_move, player_id, move}, _from, state) do
    if state.finished do
      {:reply, {:error, :game_already_over}, state}
    else
      with {:ok, color}          <- get_player_color(state, player_id),
           :ok                   <- assert_correct_turn(state, color),
           :ok                   <- assert_valid_move(state, move, color),
           {:ok, new_game_state} <- do_apply_move(state, move, color) do

        cancel_timer(state.move_timer_ref)
        next_color = next_turn(color)

        {:ok, updated_session} =
          Games.record_move(state.session_id, new_game_state, move, next_color)

        new_state = %{state |
          game_state: new_game_state,
          session: updated_session,
          turn_started_at: DateTime.utc_now(),
          move_timer_ref: nil,
          # A real move clears only this player's missed-turn streak.
          missed_turns: Map.put(state.missed_turns, color, 0),
        }

        case check_game_over(state.game_type, new_game_state) do
          {:finished, result} ->
            winner_id = result_to_winner_id(result, state)
            reason = game_over_reason(result)
            Games.finish_game(state.session_id, winner_id, result, reason)
            timing = timing_snapshot(new_state)
            final = %{new_state | finished: true}
            {:reply, {:ok, %{state: new_game_state, game_over: true, result: result, reason: reason, winner_id: winner_id, timing: timing}}, final}

          :ongoing ->
            new_state = schedule_move_timer(new_state, next_color)
            timing = timing_snapshot(new_state)
            {:reply, {:ok, %{state: new_game_state, game_over: false, timing: timing}}, new_state, @idle_stop_ms}
        end
      else
        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:resign, player_id}, _from, state) do
    cancel_timer(state.move_timer_ref)
    winner_id = other_player(player_id, state)
    result    = player_result(winner_id, state)
    Games.finish_game(state.session_id, winner_id, result, "resign")
    {:reply, {:ok, %{result: result, winner_id: winner_id, reason: "resign"}}, %{state | finished: true}}
  end

  # ── Asynchronous casts ─────────────────────────────────────────────────────

  @impl true
  def handle_cast({:player_connected, player_id}, state) do
    state = cancel_disconnect_timer(state, player_id)
    {:noreply, %{state | connected_players: MapSet.put(state.connected_players, player_id)}, @idle_stop_ms}
  end

  @impl true
  def handle_cast({:player_disconnected, player_id}, state) do
    new_connected = MapSet.delete(state.connected_players, player_id)

    state =
      if state.finished do
        state
      else
        ref = Process.send_after(self(), {:disconnect_timeout, player_id}, @disconnect_grace_ms)
        %{state | disconnect_timers: Map.put(state.disconnect_timers, player_id, ref)}
      end

    # Keep idle timer running — disconnect_timeout will fire before @idle_stop_ms
    {:noreply, %{state | connected_players: new_connected}, @idle_stop_ms}
  end

  # ── Timer / PubSub messages ────────────────────────────────────────────────

  @impl true
  def handle_info({:move_timeout, color}, state) do
    if state.finished do
      {:noreply, state}
    else
      {:noreply, handle_afk_timeout(state, color)}
    end
  end

  @impl true
  def handle_info({:disconnect_timeout, player_id}, state) do
    cond do
      state.finished ->
        {:noreply, state}

      MapSet.member?(state.connected_players, player_id) ->
        # Player reconnected in time
        {:noreply, state, @idle_stop_ms}

      true ->
        Logger.info("Player forfeited by disconnect", session_id: state.session_id, player_id: player_id)
        winner_id = other_player(player_id, state)
        result    = player_result(winner_id, state)
        Games.finish_game(state.session_id, winner_id, result, "disconnect")
        pub_broadcast(state.session_id, "game_over", %{
          result: result,
          reason: "disconnect",
          winner_id: winner_id,
        })
        {:noreply, %{state | finished: true}}
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    # GenServer idle timeout — both players vanished
    unless state.finished do
      Games.abandon_game(state.session_id)
      pub_broadcast(state.session_id, "game_over", %{result: "abandoned", reason: "abandon"})
    end
    {:stop, :normal, state}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  # A player let their move clock expire. The turn is skipped (passed to the
  # opponent) and their missed-turn streak grows. Two missed own turns forfeit
  # the game to an active opponent, or end it as a mutual-AFK draw if both have
  # gone idle. Broadcasts via PubSub so the GameChannel can push to clients.
  defp handle_afk_timeout(state, color) do
    cancel_timer(state.move_timer_ref)
    opp        = next_turn(color)
    missed     = Map.get(state.missed_turns, color, 0) + 1
    opp_missed = Map.get(state.missed_turns, opp, 0)
    state      = %{state | missed_turns: Map.put(state.missed_turns, color, missed)}

    cond do
      missed >= @afk_forfeit_misses and opp_missed >= @afk_forfeit_misses ->
        # Both players idle → mutual-AFK draw.
        Logger.info("Mutual AFK draw", session_id: state.session_id)
        Games.finish_game(state.session_id, nil, "draw", "mutual_afk")
        pub_broadcast(state.session_id, "game_over", %{
          result: "draw", reason: "mutual_afk", winner_id: nil,
        })
        %{state | finished: true, move_timer_ref: nil}

      missed >= @afk_forfeit_misses and opp_missed == 0 ->
        # Opponent is still actively playing → they win by forfeit.
        Logger.info("AFK forfeit", session_id: state.session_id, loser: color)
        winner_id = color_to_player_id(opp, state)
        result    = "#{opp}_wins"
        Games.finish_game(state.session_id, winner_id, result, "afk")
        pub_broadcast(state.session_id, "game_over", %{
          result: result, reason: "afk", loser: color, winner_id: winner_id,
        })
        %{state | finished: true, move_timer_ref: nil}

      true ->
        # No terminal outcome yet — pass the turn to the opponent.
        pass_turn(state, color, opp)
    end
  end

  # Skip the timed-out player's turn: flip the active colour without a real
  # move, persist it, and hand the clock to the opponent. A null move can leave
  # the opponent with no legal reply (rare stalemate/checkmate-on-pass), so we
  # re-check game-over before continuing.
  defp pass_turn(state, from_color, to_color) do
    new_game_state =
      state.game_state
      |> Map.put("current_turn", to_color)
      |> Map.put("en_passant_target", nil)   # passed turn expires en passant (chess); no-op for morris

    pass_record = %{"type" => "timeout_pass", "color" => from_color}

    {:ok, updated_session} =
      Games.record_move(state.session_id, new_game_state, pass_record, to_color)

    state = %{state |
      game_state: new_game_state,
      session: updated_session,
      turn_started_at: DateTime.utc_now(),
      move_timer_ref: nil,
    }

    case check_game_over(state.game_type, new_game_state) do
      {:finished, result} ->
        winner_id = result_to_winner_id(result, state)
        reason    = game_over_reason(result)
        Games.finish_game(state.session_id, winner_id, result, reason)
        pub_broadcast(state.session_id, "game_over", %{
          result: result, reason: reason, winner_id: winner_id,
        })
        %{state | finished: true}

      :ongoing ->
        new_state = schedule_move_timer(state, to_color)
        pub_broadcast(state.session_id, "turn_passed", %{
          state: new_game_state,
          skipped: from_color,
          timing: timing_snapshot(new_state),
        })
        new_state
    end
  end

  # Schedule a move-timeout message for `color`, firing after this game's
  # per-move limit (the clock resets to the full limit every turn).
  defp schedule_move_timer(state, color) do
    ref = Process.send_after(self(), {:move_timeout, color}, move_limit_ms(state.game_type))
    %{state | move_timer_ref: ref}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  defp cancel_disconnect_timer(state, player_id) do
    case Map.get(state.disconnect_timers, player_id) do
      nil -> state
      ref ->
        Process.cancel_timer(ref)
        %{state | disconnect_timers: Map.delete(state.disconnect_timers, player_id)}
    end
  end

  # Per-move clock for a live get_state call: the active player's clock counts
  # down from this game's move limit by the elapsed time of the current move;
  # the idle player shows a full fresh limit (their next turn's budget).
  defp compute_live_timing(state) do
    limit        = move_limit_ms(state.game_type)
    elapsed      = DateTime.diff(DateTime.utc_now(), state.turn_started_at, :millisecond)
    current_turn = state.game_state["current_turn"] || "white"
    active_ms    = max(0, limit - elapsed)

    {white_ms, black_ms} =
      if current_turn == "white", do: {active_ms, limit}, else: {limit, active_ms}

    %{
      white_time_ms:    white_ms,
      black_time_ms:    black_ms,
      current_turn:     current_turn,
      move_elapsed_ms:  min(elapsed, limit),
      move_limit_ms:    limit,
    }
  end

  # Timing snapshot at the start of a fresh turn — both clocks at the full limit.
  defp timing_snapshot(state) do
    limit = move_limit_ms(state.game_type)

    %{
      white_time_ms:  limit,
      black_time_ms:  limit,
      current_turn:   state.game_state["current_turn"] || "white",
      move_limit_ms:  limit,
    }
  end

  defp pub_broadcast(session_id, event, payload) do
    Phoenix.PubSub.broadcast(Vector.PubSub, "game_events:#{session_id}", {event, payload})
  end

  # ── Colour / player helpers ────────────────────────────────────────────────

  defp get_player_color(%{player_one_id: p1, player_two_id: p2}, player_id) do
    cond do
      player_id == p1 -> {:ok, "white"}
      player_id == p2 -> {:ok, "black"}
      true            -> {:error, :not_a_player}
    end
  end

  defp assert_correct_turn(%{game_state: gs}, color) do
    if gs["current_turn"] == color, do: :ok, else: {:error, :not_your_turn}
  end

  defp assert_valid_move(%{game_type: "chess", game_state: gs}, move, "white") do
    if ChessValidator.valid_move?(gs, move, :white), do: :ok, else: {:error, :invalid_move}
  end

  defp assert_valid_move(%{game_type: "chess", game_state: gs}, move, "black") do
    if ChessValidator.valid_move?(gs, move, :black), do: :ok, else: {:error, :invalid_move}
  end

  defp assert_valid_move(%{game_type: "morris", game_state: gs}, move, color) do
    if MorrisValidator.valid_move?(gs, move, color), do: :ok, else: {:error, :invalid_move}
  end

  defp do_apply_move(%{game_type: "chess", game_state: gs}, move, _color),
    do: ChessValidator.apply_move(gs, move)

  defp do_apply_move(%{game_type: "morris", game_state: gs}, move, _color),
    do: MorrisValidator.apply_move(gs, move)

  defp check_game_over("chess", state),  do: ChessValidator.check_game_over(state)
  defp check_game_over("morris", state), do: MorrisValidator.check_game_over(state)

  defp next_turn("white"), do: "black"
  defp next_turn("black"), do: "white"

  defp color_to_player_id("white", %{player_one_id: id}), do: id
  defp color_to_player_id("black", %{player_two_id: id}), do: id

  defp other_player(player_id, %{player_one_id: p1, player_two_id: p2}),
    do: if(player_id == p1, do: p2, else: p1)

  defp player_result(winner_id, %{player_one_id: p1}),
    do: if(winner_id == p1, do: "white_wins", else: "black_wins")

  defp result_to_winner_id("white_wins", %{player_one_id: p1}), do: p1
  defp result_to_winner_id("black_wins", %{player_two_id: p2}), do: p2
  defp result_to_winner_id(_, _), do: nil

  defp game_over_reason("draw"),      do: "stalemate"
  defp game_over_reason("stalemate"), do: "stalemate"
  defp game_over_reason(_),           do: "checkmate"
end
