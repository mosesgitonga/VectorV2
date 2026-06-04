defmodule Vector.Tournaments do
  import Ecto.Query
  require Logger
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

  # Tournaments waiting for a second player (pending, exactly 1 participant)
  def list_waiting_tournaments(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    Tournament
    |> join(:inner, [t], p in assoc(t, :participants))
    |> where([t, _p], t.status == "pending")
    |> group_by([t, _p], t.id)
    |> having([_t, p], count(p.id) == 1)
    |> order_by([t, _p], desc: t.inserted_at)
    |> select([t, _p], t)
    |> limit(^limit)
    |> Repo.all()
    |> Repo.preload([:creator, participants: :user])
  end

  # ── Mutations ──────────────────────────────────────────────────────────────

  def create_tournament(creator, attrs) do
    entry_fee = parse_decimal(attrs[:entry_fee] || attrs["entry_fee"])

    cond do
      creator_active_count(creator.id) >= @max_created_tournaments ->
        {:error, :tournament_limit_reached}

      has_active_game?(creator.id) ->
        {:error, :active_game_in_progress}

      true ->
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

      has_active_game?(user.id) ->
        {:error, :active_game_in_progress}

      true ->
        result =
          Repo.transaction(fn ->
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

        case result do
          {:ok, {_t, updated_user}} ->
            # Start the game now that both players have paid.
            # confirm_payment_and_start is a no-op if not all paid yet.
            confirm_payment_and_start(tournament.id)
            {:ok, {get_tournament!(tournament.id), updated_user}}

          err ->
            err
        end
    end
  end

  def confirm_payment_and_start(tournament_id) do
    # Phase 1: all DB work under a FOR UPDATE lock so two concurrent callers
    # cannot both pass the status check and create duplicate game sessions.
    result = Repo.transaction(fn ->
      tournament =
        from(t in Tournament, where: t.id == ^tournament_id, lock: "FOR UPDATE")
        |> Repo.one!()

      paid_count = paid_participant_count(tournament_id)

      cond do
        tournament.status != "pending" ->
          {:already_started}

        paid_count < tournament.max_players ->
          Repo.rollback(:not_all_paid)

        true ->
          # Fetch player IDs with direct queries — the FOR UPDATE query returns
          # a bare Tournament struct with no associations preloaded, so calling
          # get_player_id (which enumerates tournament.participants) would crash
          # with Protocol.UndefinedError on %Ecto.Association.NotLoaded{}.
          player_one_id =
            from(p in TournamentParticipant,
              where: p.tournament_id == ^tournament_id and p.seat == 1,
              select: p.user_id)
            |> Repo.one()

          player_two_id =
            from(p in TournamentParticipant,
              where: p.tournament_id == ^tournament_id and p.seat == 2,
              select: p.user_id)
            |> Repo.one()

          with {:ok, started} <- tournament |> Tournament.start_changeset() |> Repo.update(),
               {:ok, session} <-
                 Vector.Games.create_session(%{
                   tournament_id: started.id,
                   player_one_id: player_one_id,
                   player_two_id: player_two_id,
                   game_type: started.game_type
                 }) do
            {:new_session, started, session}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)

    # Phase 2: start the GameServer after the transaction commits so it can
    # read the committed game_sessions row on its own DB connection.
    case result do
      {:ok, {:already_started}} ->
        {:error, :not_all_paid}

      {:ok, {:new_session, started, session}} ->
        case Vector.Games.start_game(session.id) do
          {:ok, _pid} ->
            Task.start(fn -> Notifications.send_game_started_email(started) end)
            {:ok, started}

          {:error, reason} ->
            Logger.error("Failed to start game server after session created",
              session_id: session.id, reason: inspect(reason))
            {:error, reason}
        end

      {:error, _} = err ->
        err
    end
  end

  def on_game_finished(session) do
    tournament = get_tournament!(session.tournament_id)
    winner_id  = session.winner_id

    if winner_id do
      Repo.transaction(fn ->
        with {:ok, tournament} <-
               tournament |> Tournament.finish_changeset(winner_id) |> Repo.update() do
          prize = Tournament.prize_amount(tournament)
          case Payments.pay_winner(winner_id, tournament, prize) do
            {:ok, _} ->
              Task.start(fn -> Notifications.send_game_result_email(tournament, winner_id) end)
              tournament
            {:error, reason} ->
              Repo.rollback(reason)
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      # Draw — mark finished with no winner and refund both players' entry fees.
      Repo.transaction(fn ->
        with {:ok, updated} <- tournament |> Tournament.finish_changeset(nil) |> Repo.update(),
             {:ok, _} <- Payments.refund_tournament_participants(updated) do
          updated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def cancel_tournament(tournament) do
    Repo.transaction(fn ->
      with {:ok, updated} <- tournament |> Tournament.cancel_changeset() |> Repo.update(),
           {:ok, _} <- Payments.refund_tournament_participants(updated) do
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

  defp has_active_game?(user_id) do
    alias Vector.Games.GameSession
    GameSession
    |> where([gs], (gs.player_one_id == ^user_id or gs.player_two_id == ^user_id) and gs.status == "active")
    |> Repo.exists?()
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
