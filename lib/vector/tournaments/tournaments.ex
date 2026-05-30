defmodule Vector.Tournaments do
  import Ecto.Query
  alias Vector.Repo
  alias Vector.Accounts.User
  alias Vector.Tournaments.{Tournament, TournamentParticipant}
  alias Vector.Payments
  alias Vector.Notifications

  @max_created_tournaments 2

  # ── Queries ────────────────────────────────────────────────────────────────

  def get_tournament(id) do
    Tournament
    |> preload([:creator, :winner, participants: :user])
    |> Repo.get(id)
  end

  def get_tournament!(id) do
    Tournament
    |> preload([:creator, :winner, participants: :user])
    |> Repo.get!(id)
  end

  def get_tournament_by_invite(code) do
    Tournament
    |> where([t], fragment("UPPER(?)", t.invite_code) == ^String.upcase(code))
    |> preload([:creator, participants: :user])
    |> Repo.one()
  end

  def list_tournaments(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)
    status = Keyword.get(opts, :status)

    Tournament
    |> then(fn q -> if status, do: where(q, status: ^status), else: q end)
    |> order_by([t], desc: t.inserted_at)
    |> preload([:creator, participants: :user])
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def list_user_tournaments(user_id) do
    Tournament
    |> join(:left, [t], p in assoc(t, :participants))
    |> where([t, p], t.creator_id == ^user_id or p.user_id == ^user_id)
    |> distinct(true)
    |> preload([:creator, :winner, participants: :user])
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  # Tournaments waiting for a second player (pending, 1 participant)
  def list_waiting_tournaments(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    waiting_ids =
      TournamentParticipant
      |> group_by([p], p.tournament_id)
      |> having([p], count(p.id) == 1)
      |> select([p], p.tournament_id)
      |> Repo.all()

    Tournament
    |> where([t], t.id in ^waiting_ids and t.status == "pending")
    |> order_by([t], desc: t.inserted_at)
    |> preload([:creator, participants: :user])
    |> limit(^limit)
    |> Repo.all()
  end

  # ── Mutations ──────────────────────────────────────────────────────────────

  def create_tournament(creator, attrs) do
    entry_fee = parse_decimal(attrs[:entry_fee] || attrs["entry_fee"])

    if creator_active_count(creator.id) >= @max_created_tournaments do
      {:error, :tournament_limit_reached}
    else
      attrs = Map.put(attrs, :creator_id, creator.id)

      Repo.transaction(fn ->
        # Lock the user row and verify funds BEFORE writing any tournament record.
        # Nothing is inserted until we confirm the balance is sufficient under the lock.
        fresh_creator =
          from(u in User, where: u.id == ^creator.id, lock: "FOR UPDATE")
          |> Repo.one!()

        if Decimal.lt?(fresh_creator.balance, entry_fee) do
          Repo.rollback(:insufficient_balance)
        end

        with {:ok, tournament} <-
               %Tournament{} |> Tournament.create_changeset(attrs) |> Repo.insert(),
             {:ok, _} <- add_participant(tournament, fresh_creator),
             {:ok, _tx} <- Payments.deduct_entry_fee(fresh_creator, tournament),
             {:ok, _} <- update_prize_pool(tournament) do
          loaded = get_tournament!(tournament.id)
          updated_creator = Vector.Accounts.get_user!(creator.id)
          {loaded, updated_creator}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def join_tournament(tournament, user) do
    cond do
      tournament.status != "pending" ->
        {:error, :tournament_not_open}

      participant_count(tournament.id) >= tournament.max_players ->
        {:error, :tournament_full}

      already_participant?(tournament.id, user.id) ->
        {:error, :already_joined}

      true ->
        Repo.transaction(fn ->
          # Lock user row and verify balance BEFORE adding the participant record.
          # If funds are insufficient, no DB record is written for this join attempt.
          fresh_user =
            from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE")
            |> Repo.one!()

          if Decimal.lt?(fresh_user.balance, tournament.entry_fee) do
            Repo.rollback(:insufficient_balance)
          end

          with {:ok, _participant} <- add_participant(tournament, fresh_user),
               {:ok, _tx} <- Payments.deduct_entry_fee(fresh_user, tournament),
               {:ok, _} <- update_prize_pool(tournament) do
            updated_user = Vector.Accounts.get_user!(user.id)
            {tournament, updated_user}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  def confirm_payment_and_start(tournament_id) do
    tournament = get_tournament!(tournament_id)
    paid_count = paid_participant_count(tournament_id)

    if paid_count >= tournament.max_players do
      Repo.transaction(fn ->
        with {:ok, tournament} <-
               tournament |> Tournament.start_changeset() |> Repo.update(),
             {:ok, session} <-
               Vector.Games.create_session(%{
                 tournament_id: tournament.id,
                 player_one_id: get_player_id(tournament, 1),
                 player_two_id: get_player_id(tournament, 2),
                 game_type: tournament.game_type
               }),
             {:ok, _} <- Vector.Games.start_game(session.id) do
          Notifications.send_game_started_email(tournament)
          tournament
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :not_all_paid}
    end
  end

  def on_game_finished(session) do
    tournament = get_tournament!(session.tournament_id)
    winner_id = session.winner_id

    if winner_id do
      Repo.transaction(fn ->
        with {:ok, tournament} <-
               tournament |> Tournament.finish_changeset(winner_id) |> Repo.update() do
          prize = Tournament.prize_amount(tournament)
          Payments.pay_winner(winner_id, tournament, prize)
          Notifications.send_game_result_email(tournament, winner_id)
          tournament
        end
      end)
    end
  end

  def cancel_tournament(tournament) do
    Repo.transaction(fn ->
      with {:ok, updated} <- tournament |> Tournament.cancel_changeset() |> Repo.update(),
           :ok <- Payments.refund_tournament_participants(updated) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # ── Participant helpers ────────────────────────────────────────────────────

  def mark_participant_paid(tournament_id, user_id) do
    case Repo.get_by(TournamentParticipant, tournament_id: tournament_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      participant ->
        participant |> TournamentParticipant.paid_changeset() |> Repo.update()
    end
  end

  defp add_participant(tournament, user) do
    seat = participant_count(tournament.id) + 1

    %TournamentParticipant{}
    |> TournamentParticipant.changeset(%{
      tournament_id: tournament.id,
      user_id: user.id,
      seat: seat,
      paid_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  end

  defp update_prize_pool(tournament) do
    fresh = get_tournament!(tournament.id)
    paid_count = paid_participant_count(tournament.id)
    new_pool = Decimal.mult(fresh.entry_fee, paid_count)
    fresh |> Ecto.Changeset.change(prize_pool: new_pool) |> Repo.update()
  end

  defp participant_count(tournament_id) do
    TournamentParticipant
    |> where(tournament_id: ^tournament_id)
    |> Repo.aggregate(:count)
  end

  defp paid_participant_count(tournament_id) do
    TournamentParticipant
    |> where(tournament_id: ^tournament_id)
    |> where([p], not is_nil(p.paid_at))
    |> Repo.aggregate(:count)
  end

  defp already_participant?(tournament_id, user_id) do
    TournamentParticipant
    |> where(tournament_id: ^tournament_id, user_id: ^user_id)
    |> Repo.exists?()
  end

  defp get_player_id(tournament, seat) do
    case Enum.find(tournament.participants, &(&1.seat == seat)) do
      nil -> nil
      participant -> participant.user_id
    end
  end

  defp creator_active_count(user_id) do
    Tournament
    |> where(creator_id: ^user_id)
    |> where([t], t.status in ["pending", "active"])
    |> Repo.aggregate(:count)
  end

  defp parse_decimal(nil), do: Decimal.new(0)
  defp parse_decimal(v) when is_binary(v), do: Decimal.new(v)
  defp parse_decimal(v), do: Decimal.new("#{v}")
end
