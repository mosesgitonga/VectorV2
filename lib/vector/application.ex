defmodule Vector.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      VectorWeb.Telemetry,
      Vector.Repo,
      {DNSCluster, query: Application.get_env(:vector, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Vector.PubSub},
      {Finch, name: Vector.Finch},
      {Registry, keys: :unique, name: Vector.GameRegistry},
      Vector.Games.GameSupervisor,
      VectorWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Vector.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    VectorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
