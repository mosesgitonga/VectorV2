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
      {:ok, {tournament, transaction}} ->
        conn
        |> put_status(:created)
        |> json(%{
          tournament: tournament_json(tournament),
          payment: %{
            access_code: transaction.paystack_access_code,
            reference: transaction.paystack_reference
          }
        })

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
          {:ok, transaction} ->
            json(conn, %{
              tournament: tournament_json(tournament),
              payment: %{
                access_code: transaction.paystack_access_code,
                reference: transaction.paystack_reference
              }
            })

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: to_string(reason)})
        end
    end
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
  defp user_brief(u), do: %{id: u.id, name: u.name, avatar_url: u.avatar_url}

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(val) when is_binary(val), do: Decimal.new(val)
  defp parse_decimal(val), do: Decimal.new(to_string(val))

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp format_error(%{"message" => msg}), do: msg
  defp format_error(reason) when is_atom(reason), do: to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
