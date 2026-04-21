defmodule VectorWeb.UserController do
  use VectorWeb, :controller

  alias Vector.Accounts

  def show(conn, %{"id" => id}) do
    case Accounts.get_user(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "User not found"})

      user ->
        json(conn, %{user: public_user_json(user)})
    end
  end

  def update(conn, params) do
    user = conn.assigns.current_user
    attrs = Map.take(params, ["name", "avatar_url"])

    case Accounts.update_user_profile(user, attrs) do
      {:ok, updated_user} ->
        json(conn, %{user: private_user_json(updated_user)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  defp public_user_json(u) do
    %{id: u.id, name: u.name, avatar_url: u.avatar_url}
  end

  defp private_user_json(u) do
    %{
      id: u.id,
      email: u.email,
      name: u.name,
      avatar_url: u.avatar_url,
      role: u.role,
      email_confirmed: u.email_confirmed,
      balance: u.balance
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
