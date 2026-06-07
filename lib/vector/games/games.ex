defmodule Vector.Games do
  import Ecto.Query
  alias Vector.Repo
  alias Vector.Games.{GameSession, GameSupervisor}
  alias Vector.Games.Chess.Board, as: ChessBoard
  alias Vector.Games.Morris.Board, as: MorrisBoard

  def get_session(id), do: Repo.get(GameSession, id)

  def active_session_for(user_id) do
    GameSession
    |> where([gs], (gs.player_one_id == ^user_id or gs.player_two_id == ^user_id) and gs.status == "active")
    |> limit(1)
    |> Repo.one()
  end

  def get_session!(id), do: Repo.get!(GameSession, id)

  def list_sessions_for_tournament(tournament_id) do
    GameSession
    |> where(tournament_id: ^tournament_id)
    |> preload([:player_one, :player_two, :winner])
    |> Repo.all()
  end

  def create_session(attrs) do
    %GameSession{}
    |> GameSession.create_changeset(attrs)
    |> Repo.insert()
  end

  def start_game(session_id) do
    session = get_session!(session_id)
    initial_state = initial_state_for(session.game_type)

    with {:ok, session} <-
           session
           |> GameSession.start_changeset(initial_state)
           |> Repo.update(),
         {:ok, _pid} <- GameSupervisor.start_game(session_id) do
      {:ok, session}
    end
  end

  def record_move(session_id, new_state, move, next_turn) do
    session = get_session!(session_id)
    move_record = Map.merge(move, %{"at" => DateTime.utc_now() |> DateTime.to_iso8601()})

    session
    |> GameSession.move_changeset(new_state, move_record, next_turn)
    |> Repo.update()
  end

  def finish_game(session_id, winner_id, result, reason \\ nil) do
    session = get_session!(session_id)

    with {:ok, session} <-
           session
           |> GameSession.finish_changeset(winner_id, result, reason)
           |> Repo.update() do
      Vector.Tournaments.on_game_finished(session)
      {:ok, session}
    end
  end

  def abandon_game(session_id) do
    case get_session(session_id) do
      nil ->
        :ok

      session ->
        session |> GameSession.abandon_changeset() |> Repo.update()
    end
  end

  defp initial_state_for("chess"), do: ChessBoard.initial_state()
  defp initial_state_for("morris"), do: MorrisBoard.initial_state()
end
