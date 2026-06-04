defmodule VectorWeb.TournamentController do
  use VectorWeb, :controller

  alias Vector.Tournaments
  alias Vector.Notifications

  def index(conn, params) do
    opts = [
      limit: parse_int(params["limit"], 20),
      offset: parse_int(params["offset"], 0),
      status: params["status"]
    ]

    tournaments = Tournaments.list_tournaments(opts)
    json(conn, %{tournaments: Enum.map(tournaments, &tournament_json/1)})
  end

  def my_tournaments(conn, _params) do
    user = conn.assigns.current_user
    tournaments = Tournaments.list_user_tournaments(user.id)
    json(conn, %{tournaments: Enum.map(tournaments, &tournament_json/1)})
  end

  def show(conn, %{"id" => id}) do
    case Tournaments.get_tournament(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Tournament not found"})

      tournament ->
        json(conn, %{tournament: tournament_json(tournament)})
    end
  end

  def create(conn, params) do
    user = conn.assigns.current_user

    attrs = %{
      name: params["name"],
      game_type: params["game_type"],
      entry_fee: parse_decimal(params["entry_fee"])
    }

    case Tournaments.create_tournament(user, attrs) do
      {:ok, {tournament, updated_user}} ->
        conn
        |> put_status(:created)
        |> json(%{tournament: tournament_json(tournament), balance: updated_user.balance})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: format_error(reason)})
    end
  end

  def join(conn, %{"invite_code" => code}) do
    user = conn.assigns.current_user

    case Tournaments.get_tournament_by_invite(code) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Invalid invite code"})

      tournament ->
        case Tournaments.join_tournament(tournament, user) do
          {:ok, {refreshed_tournament, updated_user}} ->
            json(conn, %{tournament: tournament_json(refreshed_tournament), balance: updated_user.balance})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: format_error(reason)})
        end
    end
  end

  def cancel(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Tournaments.get_tournament(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Tournament not found"})

      tournament when tournament.creator_id != user.id ->
        conn |> put_status(:forbidden) |> json(%{error: "Only the creator can cancel"})

      tournament when tournament.status not in ["pending"] ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Cannot cancel a started or finished tournament"})

      tournament ->
        case Tournaments.cancel_tournament(tournament) do
          {:ok, _} -> json(conn, %{message: "Tournament cancelled and entry fees refunded"})
          {:error, _} -> conn |> put_status(:internal_server_error) |> json(%{error: "Failed to cancel"})
        end
    end
  end

  def waiting(conn, params) do
    limit = parse_int(params["limit"], 20)
    tournaments = Tournaments.list_waiting_tournaments(limit: limit)
    json(conn, %{tournaments: Enum.map(tournaments, &tournament_json/1)})
  end

  def invite(conn, %{"id" => id, "email" => email}) do
    case Tournaments.get_tournament(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Tournament not found"})

      tournament ->
        if tournament.creator_id == conn.assigns.current_user.id do
          Notifications.send_tournament_invite(email, tournament)
          json(conn, %{message: "Invitation sent to #{email}"})
        else
          conn |> put_status(:forbidden) |> json(%{error: "Only the creator can invite"})
        end
    end
  end

  def sessions(conn, %{"id" => id}) do
    sessions = Vector.Games.list_sessions_for_tournament(id)
    json(conn, %{sessions: Enum.map(sessions, &session_json/1)})
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp tournament_json(t) do
    %{
      id: t.id,
      name: t.name,
      game_type: t.game_type,
      entry_fee: t.entry_fee,
      prize_pool: t.prize_pool,
      prize_payout: Tournaments.Tournament.prize_amount(t),
      status: t.status,
      invite_code: t.invite_code,
      max_players: t.max_players,
      creator: user_brief(t.creator),
      winner: if(t.winner, do: user_brief(t.winner)),
      participants: Enum.map(t.participants || [], &participant_json/1),
      started_at: t.started_at,
      finished_at: t.finished_at,
      inserted_at: t.inserted_at
    }
  end

  defp participant_json(p) do
    %{id: p.id, user: user_brief(p.user), paid_at: p.paid_at, seat: p.seat}
  end

  defp session_json(s) do
    %{
      id: s.id,
      game_type: s.game_type,
      status: s.status,
      player_one: user_brief(s.player_one),
      player_two: user_brief(s.player_two),
      winner: if(s.winner, do: user_brief(s.winner)),
      result: s.result,
      started_at: s.started_at,
      finished_at: s.finished_at
    }
  end

  defp user_brief(nil), do: nil
  defp user_brief(%Ecto.Association.NotLoaded{}), do: nil
  defp user_brief(u), do: %{id: u.id, name: u.name, avatar_url: u.avatar_url}

  @max_limit 100

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) do
    case Integer.parse(to_string(val)) do
      {n, _} -> min(max(n, 0), @max_limit)
      :error  -> default
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(val) when is_binary(val) do
    case Decimal.parse(val) do
      {d, ""} -> d
      _       -> nil
    end
  end
  defp parse_decimal(val) do
    case Decimal.parse(to_string(val)) do
      {d, ""} -> d
      _       -> nil
    end
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @user_errors %{
    active_game_in_progress:  "You already have a game in progress. Finish it before starting another.",
    tournament_limit_reached: "You can only have 2 active tournaments at a time. Cancel or complete one first.",
    insufficient_balance:     "Insufficient wallet balance. Please deposit funds first.",
    tournament_not_open:      "This tournament is no longer accepting players.",
    tournament_full:          "This tournament is already full.",
    already_joined:           "You have already joined this tournament.",
    not_a_player:             "You are not a participant in this tournament.",
    invalid_invite_code:      "Invalid invite code. Please check and try again.",
  }

  defp format_error(%{"message" => msg}), do: msg
  defp format_error(reason) when is_atom(reason),
    do: Map.get(@user_errors, reason, "Something went wrong. Please try again.")
  defp format_error(_), do: "Something went wrong. Please try again."
end
