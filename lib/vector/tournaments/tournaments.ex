defmodule Vector.Tournaments do
  import Ecto.Query
  alias Vector.Repo
  alias Vector.Tournaments.{Tournament, TournamentParticipant}
  alias Vector.Payments
  alias Vector.Notifications

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
    |> preload([:creator, participants: :user])
    |> Repo.get_by(invite_code: code)
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

  # ── Mutations ──────────────────────────────────────────────────────────────

  def create_tournament(creator, attrs) do
    attrs = Map.put(attrs, :creator_id, creator.id)

    Repo.transaction(fn ->
      with {:ok, tournament} <-
             %Tournament{} |> Tournament.create_changeset(attrs) |> Repo.insert(),
           {:ok, _} <- add_participant(tournament, creator),
           {:ok, transaction} <-
             Payments.create_entry_fee_transaction(creator, tournament) do
        loaded = get_tournament!(tournament.id)
        {loaded, transaction}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
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
          with {:ok, _participant} <- add_participant(tournament, user),
               {:ok, transaction} <-
                 Payments.create_entry_fee_transaction(user, tournament) do
            transaction
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
      with {:ok, tournament} <-
             tournament |> Tournament.cancel_changeset() |> Repo.update() do
        Payments.refund_tournament_participants(tournament)
        tournament
      end
    end)
  end

  # ── Participant helpers ────────────────────────────────────────────────────

  def mark_participant_paid(tournament_id, user_id) do
    case Repo.get_by(TournamentParticipant, tournament_id: tournament_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      participant ->
        prize_pool_update(tournament_id)
        participant |> TournamentParticipant.paid_changeset() |> Repo.update()
    end
  end

  defp add_participant(tournament, user) do
    seat = participant_count(tournament.id) + 1

    %TournamentParticipant{}
    |> TournamentParticipant.changeset(%{
      tournament_id: tournament.id,
      user_id: user.id,
      seat: seat
    })
    |> Repo.insert()
  end

  defp prize_pool_update(tournament_id) do
    tournament = get_tournament!(tournament_id)
    new_pool = Decimal.add(tournament.prize_pool, tournament.entry_fee)
    tournament |> Ecto.Changeset.change(prize_pool: new_pool) |> Repo.update()
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
end
