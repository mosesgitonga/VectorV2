defmodule VectorWeb.Plugs.AdminPlug do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      %{role: "admin"} ->
        conn

      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Forbidden"})
        |> halt()
    end
  end
end
