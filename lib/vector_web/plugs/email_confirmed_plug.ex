defmodule VectorWeb.Plugs.EmailConfirmedPlug do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      %{email_confirmed: true} ->
        conn

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Please confirm your email address to access this feature."})
        |> halt()
    end
  end
end
