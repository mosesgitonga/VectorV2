defmodule Vector.Ranks.InactivityDecayWorker do
  @moduledoc """
  Nightly GenServer that applies one-tier rank decay to players inactive
  for 30+ days. Decay is recorded in rank_histories but does not alter ELO.
  """
  use GenServer
  require Logger

  alias Vector.Ranks.RankService

  # Run once per day (24 hours)
  @check_interval_ms 24 * 60 * 60 * 1_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    # Schedule first run after a short delay on startup
    Process.send_after(self(), :run, 60_000)
    {:ok, :ok}
  end

  @impl true
  def handle_info(:run, state) do
    Logger.info("InactivityDecayWorker: running inactivity decay check")
    Task.start(fn ->
      try do
        RankService.apply_inactivity_decay_all()
        Logger.info("InactivityDecayWorker: decay check complete")
      rescue
        e -> Logger.error("InactivityDecayWorker: error — #{inspect(e)}")
      end
    end)
    Process.send_after(self(), :run, @check_interval_ms)
    {:noreply, state}
  end
end
