defmodule VectorWeb.CacheBodyReader do
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = update_in(conn.assigns[:raw_body], fn existing -> (existing || "") <> body end)
    {:ok, body, conn}
  end
end
