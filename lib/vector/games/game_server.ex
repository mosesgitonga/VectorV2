defmodule Vector.Games.GameServer do
  @moduledoc """
  GenServer managing in-memory state for one active game session.

  Time control rules (enforced server-side, not trusting client):
    - Each player has 30 minutes total across the whole game
    - No single move may take more than 10 minutes
    - Whichever limit is hit first causes an immediate forfeit
    - If a player disconnects and does not reconnect within 3 minutes,
      they forfeit (unless the game is already over)

  Edge cases handled:
    - Wrong-turn submissions → rejected
    - Illegal moves → rejected (server validates via MoveValidator)
    - Double-move race: GenServer serialises all calls, so only one
      `make_move` runs at a time
    - Self-play manipulation: colour assigned at session creation, not client
    - Replay attacks: each move deducts real elapsed wall-clock time
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

  @move_limit_ms       10 * 60 * 1_000   # 10-min cap per move
  @total_time_ms       30 * 60 * 1_000   # 30-min total per player
  @disconnect_grace_ms  3 * 60 * 1_000   # 3-min reconnect window
  @idle_stop_ms        15 * 60 * 1_000   # kill idle GenServer after 15 min

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
      # Time tracking
      white_time_ms: @total_time_ms,
      black_time_ms: @total_time_ms,
      turn_started_at: DateTime.utc_now(),
      move_timer_ref: nil,
      # Connection
      connected_players: MapSet.new(),
      disconnect_timers: %{},
      session: session,
      finished: false,
    }

    # White moves first — start the 10-min move clock now
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
           {:ok, timed_state}    <- deduct_elapsed_time(state, color),
           :ok                   <- assert_valid_move(state, move, color),
           {:ok, new_game_state} <- do_apply_move(state, move, color) do

        cancel_timer(state.move_timer_ref)
        next_color = next_turn(color)

        {:ok, updated_session} =
          Games.record_move(state.session_id, new_game_state, move, next_color)

        new_state = %{timed_state |
          game_state: new_game_state,
          session: updated_session,
          turn_started_at: DateTime.utc_now(),
          move_timer_ref: nil,
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
        {:error, :time_exceeded} ->
          # Player exhausted their time allowance mid-move
          new_state = do_finish_timeout(state, get_color!(state, player_id))
          {:reply, {:error, :time_exceeded}, new_state}

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
      new_state = do_finish_timeout(state, color)
      {:noreply, new_state}
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

  # Finish a game due to a player running out of time.
  # Broadcasts game_over via PubSub so the GameChannel can push it to clients.
  defp do_finish_timeout(state, loser_color) do
    Logger.info("Game timeout", session_id: state.session_id, loser: loser_color)
    cancel_timer(state.move_timer_ref)
    winner_color = next_turn(loser_color)
    winner_id    = color_to_player_id(winner_color, state)
    result       = "#{winner_color}_wins"
    Games.finish_game(state.session_id, winner_id, result, "timeout")
    pub_broadcast(state.session_id, "game_over", %{
      result: result,
      reason: "timeout",
      loser: loser_color,
      winner_id: winner_id,
    })
    %{state | finished: true, move_timer_ref: nil}
  end

  # Schedule a move-timeout message for `color`.
  # Fires after min(player's remaining total time, @move_limit_ms).
  defp schedule_move_timer(state, color) do
    time_left = Map.get(state, :"#{color}_time_ms")
    timeout   = min(time_left, @move_limit_ms)
    ref       = Process.send_after(self(), {:move_timeout, color}, timeout)
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

  # Deduct wall-clock elapsed time from the current player's total.
  # Caps the deduction at @move_limit_ms (10 min) — you can't lose more
  # than one move's worth of time even if you stall longer.
  defp deduct_elapsed_time(state, color) do
    elapsed  = DateTime.diff(DateTime.utc_now(), state.turn_started_at, :millisecond)
    deducted = min(elapsed, @move_limit_ms)
    key      = :"#{color}_time_ms"
    remaining = Map.get(state, key) - deducted

    if remaining <= 0 do
      {:error, :time_exceeded}
    else
      {:ok, Map.put(state, key, remaining)}
    end
  end

  # Build timing for a get_state call — adjusts the active player's display
  # time by subtracting the elapsed time of the current move.
  defp compute_live_timing(state) do
    elapsed      = DateTime.diff(DateTime.utc_now(), state.turn_started_at, :millisecond)
    current_turn = state.game_state["current_turn"] || "white"

    {white_ms, black_ms} =
      if current_turn == "white" do
        {max(0, state.white_time_ms - elapsed), state.black_time_ms}
      else
        {state.white_time_ms, max(0, state.black_time_ms - elapsed)}
      end

    %{
      white_time_ms:    white_ms,
      black_time_ms:    black_ms,
      current_turn:     current_turn,
      move_elapsed_ms:  min(elapsed, @move_limit_ms),
      move_limit_ms:    @move_limit_ms,
      total_limit_ms:   @total_time_ms,
    }
  end

  # Build timing snapshot after a move (times already updated in state).
  defp timing_snapshot(state) do
    %{
      white_time_ms:  state.white_time_ms,
      black_time_ms:  state.black_time_ms,
      current_turn:   state.game_state["current_turn"] || "white",
      move_limit_ms:  @move_limit_ms,
      total_limit_ms: @total_time_ms,
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

  defp get_color!(state, player_id) do
    {:ok, color} = get_player_color(state, player_id)
    color
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
