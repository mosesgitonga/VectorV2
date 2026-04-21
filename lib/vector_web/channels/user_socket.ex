defmodule VectorWeb.UserSocket do
  use Phoenix.Socket

  channel "game:*", VectorWeb.GameChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Vector.Accounts.Guardian.decode_and_verify(token) do
      {:ok, claims} ->
        case Vector.Accounts.Guardian.resource_from_claims(claims) do
          {:ok, user} ->
            {:ok, assign(socket, :current_user, user)}

          {:error, _} ->
            :error
        end

      {:error, _} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"
end
