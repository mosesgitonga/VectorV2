import Config

if System.get_env("PHX_SERVER") do
  config :vector, VectorWeb.Endpoint, server: true
end

config :vector, VectorWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# App-level config — only override values that are explicitly set in the environment
# so that dev.exs defaults are preserved when env vars are absent
app_url = System.get_env("APP_URL", "http://localhost:4000")

config :vector,
  app_url: System.get_env("FRONTEND_URL", "http://localhost:3000"),
  google_client_id: System.get_env("GOOGLE_CLIENT_ID", ""),
  google_client_secret: System.get_env("GOOGLE_CLIENT_SECRET", ""),
  google_redirect_uri: System.get_env("GOOGLE_REDIRECT_URI", "#{app_url}/api/auth/google/callback")

if paystack_key = System.get_env("PAYSTACK_SECRET_KEY") do
  config :vector, paystack_secret_key: paystack_key
end

guardian_secret =
  if config_env() == :prod do
    System.get_env("GUARDIAN_SECRET") ||
      raise "environment variable GUARDIAN_SECRET is missing."
  else
    System.get_env("GUARDIAN_SECRET", "dev_secret_not_for_production")
  end

config :vector, Vector.Accounts.Guardian,
  secret_key: guardian_secret,
  token_ttl: %{"access" => {24, :hours}}

# Swoosh uses SMTP (gen_smtp) — no HTTP API client needed
config :swoosh, :api_client, false

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing."

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :vector, Vector.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing."

  host = System.get_env("PHX_HOST") || "example.com"

  frontend_url_for_check =
    System.get_env("FRONTEND_URL") || raise "environment variable FRONTEND_URL is missing."

  config :vector, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :vector, VectorWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base,
    # Allow WebSocket connections from the frontend origin.
    # Without this Phoenix rejects connections from a different host.
    check_origin: [frontend_url_for_check, "http://localhost:3000", "http://localhost:4000"]

  config :vector, Vector.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: System.get_env("SMTP_HOST", "smtp.gmail.com"),
    port: String.to_integer(System.get_env("SMTP_PORT", "587")),
    username: System.get_env("SMTP_USER"),
    password: System.get_env("SMTP_PASS"),
    tls: :always,
    auth: :always

  frontend_url =
    System.get_env("FRONTEND_URL") ||
      raise "environment variable FRONTEND_URL is missing."

  config :cors_plug,
    origin: [frontend_url],
    methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    headers: ["Authorization", "Content-Type", "Accept", "Origin"],
    max_age: 86400
end
