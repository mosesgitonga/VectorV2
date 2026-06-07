defmodule VectorWeb.Presence do
  @moduledoc """
  Tracks which users are currently connected via sockets (e.g. for showing
  online status on tournament listings).
  """
  use Phoenix.Presence,
    otp_app: :vector,
    pubsub_server: Vector.PubSub
end
