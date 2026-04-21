defmodule VectorWeb.AdminController do
  use VectorWeb, :controller

  alias Vector.Admin

  def dashboard(conn, _params) do
    stats = Admin.dashboard_stats()
    json(conn, %{stats: stats})
  end

  # ── Users ──────────────────────────────────────────────────────────────────

  def list_users(conn, params) do
    opts = [
      limit: parse_int(params["limit"], 50),
      offset: parse_int(params["offset"], 0)
    ]

    users = Admin.list_users(opts)
    json(conn, %{users: Enum.map(users, &admin_user_json/1)})
  end

  def update_user(conn, %{"id" => id} = params) do
    role = params["role"]
    active = params["is_active"]

    cond do
      role ->
        case Admin.update_user_role(id, role) do
          {:ok, user} -> json(conn, %{user: admin_user_json(user)})
          {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
        end

      not is_nil(active) ->
        if active do
          case Admin.activate_user(id) do
            {:ok, user} -> json(conn, %{user: admin_user_json(user)})
            {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
          end
        else
          case Admin.deactivate_user(id) do
            {:ok, user} -> json(conn, %{user: admin_user_json(user)})
            {:error, cs} -> conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(cs)})
          end
        end

      true ->
        conn |> put_status(:bad_request) |> json(%{error: "No valid update params provided"})
    end
  end

  # ── Tournaments ────────────────────────────────────────────────────────────

  def list_tournaments(conn, params) do
    opts = [
      limit: parse_int(params["limit"], 50),
      offset: parse_int(params["offset"], 0),
      status: params["status"]
    ]

    tournaments = Admin.list_tournaments(opts)
    json(conn, %{tournaments: tournaments})
  end

  def cancel_tournament(conn, %{"id" => id}) do
    case Admin.cancel_tournament(id) do
      {:ok, tournament} ->
        json(conn, %{tournament: tournament, message: "Tournament cancelled and refunds issued"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  # ── Transactions ───────────────────────────────────────────────────────────

  def list_transactions(conn, params) do
    opts = [
      limit: parse_int(params["limit"], 50),
      offset: parse_int(params["offset"], 0)
    ]

    transactions = Admin.list_transactions(opts)
    json(conn, %{transactions: transactions})
  end

  def revenue(conn, params) do
    days = parse_int(params["days"], 30)
    amount = Admin.get_revenue_by_period(days)
    json(conn, %{revenue: amount, period_days: days})
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp admin_user_json(u) do
    %{
      id: u.id,
      email: u.email,
      name: u.name,
      role: u.role,
      is_active: u.is_active,
      email_confirmed: u.email_confirmed,
      balance: u.balance,
      inserted_at: u.inserted_at
    }
  end

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
