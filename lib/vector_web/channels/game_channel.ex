defmodule VectorWeb.GameChannel do
  use Phoenix.Channel

  alias Vector.Games
  alias Vector.Games.GameServer

  @impl true
  def join("game:" <> session_id, _params, socket) do
    user = socket.assigns.current_user

    case Games.get_session(session_id) do
      nil ->
        {:error, %{reason: "session_not_found"}}

      session ->
        if player_in_session?(session, user.id) do
          send(self(), {:after_join, session_id})
          {:ok, %{session_id: session_id}, assign(socket, :session_id, session_id)}
        else
          {:error, %{reason: "not_authorized"}}
        end
    end
  end

  @impl true
  def handle_info({:after_join, session_id}, socket) do
    user_id = socket.assigns.current_user.id
    GameServer.player_connected(session_id, user_id)

    case GameServer.get_state(session_id) do
      {:ok, state} ->
        push(socket, "game_state", %{state: state.game_state})

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  @impl true
  def handle_in("make_move", %{"move" => move}, socket) do
    session_id = socket.assigns.session_id
    user_id = socket.assigns.current_user.id

    case GameServer.make_move(session_id, user_id, move) do
      {:ok, result} ->
        broadcast!(socket, "move_made", %{
          move: move,
          state: result.state,
          game_over: result.game_over,
          result: Map.get(result, :result)
        })

        {:reply, {:ok, result}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("resign", _params, socket) do
    session_id = socket.assigns.session_id
    user_id = socket.assigns.current_user.id

    case GameServer.resign(session_id, user_id) do
      {:ok, result} ->
        broadcast!(socket, "game_over", result)
        {:reply, {:ok, result}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("ping", _params, socket) do
    {:reply, {:ok, %{pong: true}}, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    session_id = socket.assigns[:session_id]
    user_id = socket.assigns.current_user.id

    if session_id do
      GameServer.player_disconnected(session_id, user_id)
    end

    :ok
  end

  defp player_in_session?(session, user_id) do
    session.player_one_id == user_id or session.player_two_id == user_id
  end
end
