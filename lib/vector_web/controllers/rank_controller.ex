defmodule VectorWeb.RankController do
  use VectorWeb, :controller

  import Ecto.Query
  alias Vector.Repo
  alias Vector.Accounts.User
  alias Vector.Ranks.RankService

  @doc "Top players by ELO for a given game_type (default chess, limit 50)."
  def leaderboard(conn, params) do
    game_type = params["game_type"] || "chess"
    limit     = min(String.to_integer(params["limit"] || "50"), 100)

    {elo_col, _games_col} = case game_type do
      "morris" -> {:elo_morris, :games_played_morris}
      _        -> {:elo_chess,  :games_played_chess}
    end

    players =
      User
      |> where([u], u.is_active == true)
      |> order_by([u], desc: field(u, ^elo_col))
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(fn u ->
        {elo, games} = RankService.player_stats(u, game_type)
        rank_name    = RankService.calculate_rank(elo, games, game_type)
        rank_info    = if rank_name, do: RankService.find_rank(rank_name)

        %{
          id:          u.id,
          name:        u.name,
          avatar_url:  u.avatar_url,
          elo:         elo,
          games_played: games,
          rank:        rank_name,
          rank_emoji:  if(rank_info, do: rank_info.emoji),
        }
      end)

    json(conn, %{game_type: game_type, players: players})
  end
end
