import Config

config :vector,
  ecto_repos: [Vector.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :vector, VectorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: VectorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Vector.PubSub,
  live_view: [signing_salt: "RlpRZ+Pi"]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Guardian JWT
config :vector, Vector.Accounts.Guardian,
  issuer: "vector",
  secret_key: "CHANGE_ME_IN_RUNTIME"

# Ueberauth Google OAuth
config :ueberauth, Ueberauth,
  providers: [
    google: {Ueberauth.Strategy.Google, [default_scope: "email profile"]}
  ]

config :ueberauth, Ueberauth.Strategy.Google.OAuth,
  client_id: System.get_env("GOOGLE_CLIENT_ID"),
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET")

# Swoosh email
config :vector, Vector.Mailer, adapter: Swoosh.Adapters.SMTP

# CORS — overridden per environment in runtime.exs (prod) or dev.exs
config :cors_plug,
  origin: "*",
  max_age: 86_400,
  methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
  headers: ["Authorization", "Content-Type", "Accept", "Origin"]

import_config "#{config_env()}.exs"
