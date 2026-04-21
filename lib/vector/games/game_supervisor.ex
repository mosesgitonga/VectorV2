defmodule Vector.Games.GameSupervisor do
  use DynamicSupervisor

  alias Vector.Games.GameServer

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_game(session_id) do
    case Registry.lookup(Vector.GameRegistry, session_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(__MODULE__, {GameServer, session_id})
    end
  end

  def stop_game(session_id) do
    case Registry.lookup(Vector.GameRegistry, session_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end
  end
end
