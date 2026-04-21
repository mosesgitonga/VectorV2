defmodule Vector.Admin do
  import Ecto.Query
  alias Vector.Repo
  alias Vector.Accounts
  alias Vector.Payments
  alias Vector.Tournaments
  alias Vector.Accounts.User
  alias Vector.Tournaments.Tournament
  alias Vector.Payments.Transaction

  # ── Dashboard stats ────────────────────────────────────────────────────────

  def dashboard_stats do
    %{
      total_users: Accounts.count_users(),
      total_tournaments: Repo.aggregate(Tournament, :count),
      active_tournaments: count_by_status(Tournament, "active"),
      total_revenue: Payments.total_revenue() || Decimal.new(0),
      pending_transactions: count_by_status(Transaction, "pending"),
      recent_users: Accounts.list_users(limit: 5),
      recent_tournaments: Tournaments.list_tournaments(limit: 5)
    }
  end

  # ── User management ────────────────────────────────────────────────────────

  def list_users(opts \\ []), do: Accounts.list_users(opts)

  def get_user(id), do: Accounts.get_user(id)

  def update_user_role(user_id, role) do
    user = Accounts.get_user!(user_id)
    user |> User.admin_changeset(%{role: role}) |> Repo.update()
  end

  def deactivate_user(user_id) do
    user = Accounts.get_user!(user_id)
    user |> User.admin_changeset(%{is_active: false}) |> Repo.update()
  end

  def activate_user(user_id) do
    user = Accounts.get_user!(user_id)
    user |> User.admin_changeset(%{is_active: true}) |> Repo.update()
  end

  # ── Tournament management ──────────────────────────────────────────────────

  def list_tournaments(opts \\ []), do: Tournaments.list_tournaments(opts)

  def cancel_tournament(tournament_id) do
    tournament = Tournaments.get_tournament!(tournament_id)
    Tournaments.cancel_tournament(tournament)
  end

  # ── Transaction management ─────────────────────────────────────────────────

  def list_transactions(opts \\ []), do: Payments.list_all_transactions(opts)

  def get_revenue_by_period(days \\ 30) do
    from_date = DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60, :second)

    Transaction
    |> where([t], t.inserted_at >= ^from_date and t.type == "entry_fee" and t.status == "success")
    |> Repo.aggregate(:sum, :amount)
    |> Decimal.mult(Decimal.new("0.15"))
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp count_by_status(schema, status) do
    schema
    |> where(status: ^status)
    |> Repo.aggregate(:count)
  end
end
