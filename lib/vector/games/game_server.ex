defmodule Vector.Games.GameServer do
  @moduledoc """
  GenServer managing in-memory state for an active game session.
  One process per active game, registered via Registry.
  """
  use GenServer, restart: :transient

  alias Vector.Games
  alias Vector.Games.{Chess.MoveValidator, Morris.MoveValidator}

  @idle_timeout_ms 10 * 60 * 1_000

  # ── Public API ─────────────────────────────────────────────────────────────

  def start_link(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  def get_state(session_id) do
    GenServer.call(via(session_id), :get_state)
  end

  def make_move(session_id, player_id, move) do
    GenServer.call(via(session_id), {:make_move, player_id, move})
  end

  def player_connected(session_id, player_id) do
    GenServer.cast(via(session_id), {:player_connected, player_id})
  end

  def player_disconnected(session_id, player_id) do
    GenServer.cast(via(session_id), {:player_disconnected, player_id})
  end

  def resign(session_id, player_id) do
    GenServer.call(via(session_id), {:resign, player_id})
  end

  def via(session_id), do: {:via, Registry, {Vector.GameRegistry, session_id}}

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl true
  def init(session_id) do
    session = Games.get_session!(session_id)

    state = %{
      session_id: session_id,
      game_type: session.game_type,
      player_one_id: session.player_one_id,
      player_two_id: session.player_two_id,
      game_state: session.state,
      connected_players: MapSet.new(),
      session: session
    }

    {:ok, state, @idle_timeout_ms}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state, @idle_timeout_ms}
  end

  @impl true
  def handle_call({:make_move, player_id, move}, _from, state) do
    with {:ok, color} <- get_player_color(state, player_id),
         true <- correct_turn?(state, color),
         true <- validate_move(state, move, color),
         {:ok, new_game_state} <- apply_move(state, move, color),
         {:ok, updated_session} <- Games.record_move(state.session_id, new_game_state, move, next_turn(color)) do
      game_over = check_game_over(state.game_type, new_game_state)
      new_server_state = %{state | game_state: new_game_state, session: updated_session}

      if game_over != :ongoing do
        {:finished, result} = game_over
        winner_id = result_to_winner_id(result, state)
        Games.finish_game(state.session_id, winner_id, result)
        {:reply, {:ok, %{state: new_game_state, game_over: true, result: result}}, new_server_state}
      else
        {:reply, {:ok, %{state: new_game_state, game_over: false}}, new_server_state, @idle_timeout_ms}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state, @idle_timeout_ms}
      false -> {:reply, {:error, :invalid_move}, state, @idle_timeout_ms}
    end
  end

  @impl true
  def handle_call({:resign, player_id}, _from, state) do
    winner_id =
      if player_id == state.player_one_id,
        do: state.player_two_id,
        else: state.player_one_id

    result = if winner_id == state.player_one_id, do: "white_wins", else: "black_wins"
    Games.finish_game(state.session_id, winner_id, result)
    {:reply, {:ok, %{result: result, winner_id: winner_id}}, state}
  end

  @impl true
  def handle_cast({:player_connected, player_id}, state) do
    {:noreply, %{state | connected_players: MapSet.put(state.connected_players, player_id)},
     @idle_timeout_ms}
  end

  @impl true
  def handle_cast({:player_disconnected, player_id}, state) do
    {:noreply,
     %{state | connected_players: MapSet.delete(state.connected_players, player_id)},
     @idle_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    Games.abandon_game(state.session_id)
    {:stop, :normal, state}
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp get_player_color(%{player_one_id: p1, player_two_id: p2}, player_id) do
    cond do
      player_id == p1 -> {:ok, "white"}
      player_id == p2 -> {:ok, "black"}
      true -> {:error, :not_a_player}
    end
  end

  defp correct_turn?(%{game_state: gs}, color) do
    gs["current_turn"] == color
  end

  defp validate_move(%{game_type: "chess", game_state: gs}, move, color) do
    MoveValidator.valid_move?(gs, move, String.to_atom(color))
  end

  defp validate_move(%{game_type: "morris", game_state: gs}, move, color) do
    Vector.Games.Morris.MoveValidator.valid_move?(gs, move, color)
  end

  defp apply_move(%{game_type: "chess", game_state: gs}, move, _color) do
    MoveValidator.apply_move(gs, move)
  end

  defp apply_move(%{game_type: "morris", game_state: gs}, move, _color) do
    Vector.Games.Morris.MoveValidator.apply_move(gs, move)
  end

  defp check_game_over("chess", state), do: MoveValidator.check_game_over(state)
  defp check_game_over("morris", state), do: Vector.Games.Morris.MoveValidator.check_game_over(state)

  defp next_turn("white"), do: "black"
  defp next_turn("black"), do: "white"

  defp result_to_winner_id("white_wins", %{player_one_id: p1}), do: p1
  defp result_to_winner_id("black_wins", %{player_two_id: p2}), do: p2
  defp result_to_winner_id(_, _), do: nil
end
