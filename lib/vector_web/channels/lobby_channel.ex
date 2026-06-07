defmodule VectorWeb.LobbyChannel do
  @moduledoc """
  Tracks which authenticated users are currently online so the frontend can
  show live "online" indicators (e.g. next to a tournament creator's name).

  Any authenticated socket may join "lobby:online". Presence diffs are
  broadcast by Phoenix.Presence directly to the topic and relayed to clients
  automatically — no explicit broadcast/handle_out is needed here.
  """
  use Phoenix.Channel

  alias VectorWeb.Presence

  @impl true
  def join("lobby:online", _params, socket) do
    send(self(), :after_join)
    {:ok, socket}
  end

  @impl true
  def handle_info(:after_join, socket) do
    user_id = socket.assigns.current_user.id

    {:ok, _} = Presence.track(socket, user_id, %{online_at: System.system_time(:second)})
    push(socket, "presence_state", Presence.list(socket))

    {:noreply, socket}
  end
end
