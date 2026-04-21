defmodule VectorWeb.GameController do
  use VectorWeb, :controller

  alias Vector.Games

  def show(conn, %{"id" => id}) do
    case Games.get_session(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Game session not found"})

      session ->
        user = conn.assigns.current_user

        if session.player_one_id == user.id or session.player_two_id == user.id do
          json(conn, %{session: session_json(session)})
        else
          conn |> put_status(:forbidden) |> json(%{error: "Not your game"})
        end
    end
  end

  defp session_json(s) do
    %{
      id: s.id,
      tournament_id: s.tournament_id,
      game_type: s.game_type,
      status: s.status,
      state: s.state,
      move_history: s.move_history,
      current_turn: s.current_turn,
      result: s.result,
      player_one_id: s.player_one_id,
      player_two_id: s.player_two_id,
      winner_id: s.winner_id,
      started_at: s.started_at,
      finished_at: s.finished_at
    }
  end
end
