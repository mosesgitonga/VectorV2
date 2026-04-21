defmodule Vector.MixProject do
  use Mix.Project

  def project do
    [
      app: :vector,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Vector.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix
      {:phoenix, "~> 1.7"},
      {:phoenix_ecto, "~> 4.6"},
      {:phoenix_live_view, "~> 0.20"},
      {:phoenix_live_dashboard, "~> 0.8"},

      # Database
      {:ecto_sql, "~> 3.11"},
      {:postgrex, "~> 0.18"},

      # Auth
      {:guardian, "~> 2.3"},
      {:ueberauth, "~> 0.10"},
      {:ueberauth_google, "~> 0.10"},
      {:bcrypt_elixir, "~> 3.0"},

      # HTTP client (for Paystack API calls)
      {:finch, "~> 0.18"},
      {:jason, "~> 1.4"},
      {:gettext, "~> 0.20"},
      {:telemetry_poller, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},

      # Email
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.2"},

      # HTTP server
      {:bandit, "~> 1.5"},

      # Rate limiting
      {:ex_rated, "~> 2.1"},

      # Clustering
      {:dns_cluster, "~> 0.1"},

      # Utilities
      {:cors_plug, "~> 3.0"},

      # Dev/test
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:ex_machina, "~> 2.7", only: :test},
      {:faker, "~> 0.18", only: :test},
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end