defmodule Vector.Repo do
  use Ecto.Repo,
    otp_app: :vector,
    adapter: Ecto.Adapters.Postgres
end
