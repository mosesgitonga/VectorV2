defmodule Vector.Ranks.RankService do
  @moduledoc """
  Player ranking, ELO calculation, and stake-limit enforcement.

  Rank is determined by the LOWER of two independently computed tiers:
    - ELO tier  (which ELO band the player falls into)
    - Games tier (how many games they have played)

  A player must meet BOTH the ELO minimum AND the games minimum to hold a rank.
  Players with fewer than 10 games show as nil (Unranked).

  The system is game-type-agnostic: pass any game_type string and the
  service reads/writes the matching column (elo_{game_type}, games_played_{game_type}).
  When new games are added, add a migration + include the column name here.
  """

  import Ecto.Query
  require Logger

  alias Vector.Repo
  alias Vector.Accounts.User
  alias Vector.Ranks.RankHistory

  # ── Rank table ─────────────────────────────────────────────────────────────
  # Ordered ascending by level. Both elo_min and games_min are inclusive minima.

  @ranks [
    %{level: 1, name: "Pawn",     emoji: "♟️",  elo_min: 0,    games_min: 0,   max_pool: 500,   cut: "0.20"},
    %{level: 2, name: "Hunter",   emoji: "🏹",  elo_min: 1000, games_min: 10,  max_pool: 1000,  cut: "0.18"},
    %{level: 3, name: "Knight",   emoji: "♞",   elo_min: 1200, games_min: 25,  max_pool: 2500,  cut: "0.15"},
    %{level: 4, name: "Predator", emoji: "🐺",  elo_min: 1400, games_min: 50,  max_pool: 5000,  cut: "0.13"},
    %{level: 5, name: "Warlord",  emoji: "⚔️",  elo_min: 1600, games_min: 100, max_pool: 10000, cut: "0.11"},
    %{level: 6, name: "Shark",    emoji: "🦈",  elo_min: 1800, games_min: 200, max_pool: 25000, cut: "0.09"},
    %{level: 7, name: "Dragon",   emoji: "🐉",  elo_min: 2000, games_min: 350, max_pool: 50000, cut: "0.085"},
    %{level: 8, name: "God Mode", emoji: "⚡",  elo_min: 2200, games_min: 500, max_pool: nil,   cut: "0.08"},
  ]

  @unranked_games_threshold 0
  @god_mode_top_percentile  0.01  # top 1% of active players

  # ── ELO calculation ────────────────────────────────────────────────────────

  @doc """
  Recalculate a player's ELO after one game.

  games_played is the count BEFORE this game (used to determine K-factor).
  result is :win | :loss | :draw
  Returns the new integer ELO (never drops below 100).
  """
  def calculate_elo(player_elo, opponent_elo, result, games_played) do
    k         = if games_played >= 100, do: 16, else: 32
    expected  = 1.0 / (1.0 + :math.pow(10, (opponent_elo - player_elo) / 400.0))
    actual    = result_score(result)
    new_elo   = round(player_elo + k * (actual - expected))
    max(100, new_elo)
  end

  # ── Rank calculation ───────────────────────────────────────────────────────

  @doc """
  Calculate rank name from ELO and games played.
  Returns nil when the player is unranked (fewer than 10 games).
  God Mode is additionally capped to top 1% of active players by ELO.
  """
  def calculate_rank(elo, games_played, game_type \\ nil) do
    if games_played < @unranked_games_threshold do
      nil
    else
      elo_level   = elo_to_level(elo)
      games_level = games_to_level(games_played)
      level       = min(elo_level, games_level)

      rank = rank_at_level(level)

      # God Mode cap: top 1% of active players only
      if rank.name == "God Mode" and not is_nil(game_type) do
        if in_god_mode_percentile?(elo, game_type) do
          "God Mode"
        else
          "Dragon"
        end
      else
        rank.name
      end
    end
  end

  @doc "All rank definitions (for frontend reference)."
  def all_ranks, do: @ranks

  @doc "Find rank definition by name."
  def find_rank(name), do: Enum.find(@ranks, &(&1.name == name))

  # ── Platform cut ───────────────────────────────────────────────────────────

  @doc "Platform cut as a Decimal for a rank name. nil/unranked → Pawn cut (20%)."
  def get_platform_cut(nil),       do: Decimal.new("0.20")
  def get_platform_cut(rank_name) do
    case find_rank(rank_name) do
      nil  -> Decimal.new("0.20")
      rank -> Decimal.new(rank.cut)
    end
  end

  @doc """
  Determine the platform cut for a tournament based on both players' ranks.
  Rule: use the cut of the LOWER-ranked player (higher cut = more protection).
  """
  def tournament_platform_cut(player_one, player_two, game_type) do
    {elo1, g1} = player_stats(player_one, game_type)
    {elo2, g2} = player_stats(player_two, game_type)
    rank1 = calculate_rank(elo1, g1, game_type)
    rank2 = calculate_rank(elo2, g2, game_type)
    level1 = rank_level(rank1)
    level2 = rank_level(rank2)
    lower_rank = if level1 <= level2, do: rank1, else: rank2
    get_platform_cut(lower_rank)
  end

  # ── Stake limits ───────────────────────────────────────────────────────────

  @doc "Maximum tournament pool (KES) for a rank. nil = no limit (God Mode)."
  def get_max_pool(nil),       do: 500
  def get_max_pool(rank_name) do
    case find_rank(rank_name) do
      nil  -> 500
      rank -> rank.max_pool
    end
  end

  @doc "Maximum entry fee per player for a 1v1 tournament."
  def get_max_entry_fee(rank_name) do
    case get_max_pool(rank_name) do
      nil  -> :unlimited
      pool -> div(pool, 2)
    end
  end

  @doc """
  Check whether a player's rank allows joining a tournament at the given entry fee.

  Returns :ok or {:error, {current_rank, next_rank_info}} where next_rank_info
  contains the name and max_pool of the next rank tier.
  """
  def check_stake_limit(user, game_type, entry_fee) do
    {elo, games} = player_stats(user, game_type)
    rank         = calculate_rank(elo, games, game_type)
    case get_max_entry_fee(rank) do
      :unlimited -> :ok
      max_fee ->
        fee = to_decimal(entry_fee)
        if Decimal.compare(fee, Decimal.new("#{max_fee}")) != :gt do
          :ok
        else
          {:error, {rank, next_rank_info(rank)}}
        end
    end
  end

  # ── ELO + rank update after game ──────────────────────────────────────────

  @doc """
  Update ELO, games_played, and rank for both players after a completed game.

  session must have player_one_id, player_two_id, result, game_type.
  Writes to rank_histories if rank changed.
  Returns {:ok, {updated_p1, updated_p2}}.
  """
  def update_rank_after_game(session) do
    %{
      player_one_id: p1_id,
      player_two_id: p2_id,
      result:        result,
      game_type:     game_type
    } = session

    Repo.transaction(fn ->
      p1 = from(u in User, where: u.id == ^p1_id, lock: "FOR UPDATE") |> Repo.one!()
      p2 = from(u in User, where: u.id == ^p2_id, lock: "FOR UPDATE") |> Repo.one!()

      {p1_elo, p1_games} = player_stats(p1, game_type)
      {p2_elo, p2_games} = player_stats(p2, game_type)

      {p1_result, p2_result} = split_result(result)

      new_p1_elo   = calculate_elo(p1_elo, p2_elo, p1_result, p1_games)
      new_p2_elo   = calculate_elo(p2_elo, p1_elo, p2_result, p2_games)
      new_p1_games = p1_games + 1
      new_p2_games = p2_games + 1

      old_p1_rank = calculate_rank(p1_elo, p1_games, game_type)
      old_p2_rank = calculate_rank(p2_elo, p2_games, game_type)
      new_p1_rank = calculate_rank(new_p1_elo, new_p1_games, game_type)
      new_p2_rank = calculate_rank(new_p2_elo, new_p2_games, game_type)

      {:ok, p1_out} = p1 |> apply_stats_changeset(game_type, new_p1_elo, new_p1_games) |> Repo.update()
      {:ok, p2_out} = p2 |> apply_stats_changeset(game_type, new_p2_elo, new_p2_games) |> Repo.update()

      if old_p1_rank != new_p1_rank,
        do: record_rank_change(p1_id, game_type, old_p1_rank, new_p1_rank, "elo_change")
      if old_p2_rank != new_p2_rank,
        do: record_rank_change(p2_id, game_type, old_p2_rank, new_p2_rank, "elo_change")

      Logger.info("ELO updated",
        game_type: game_type,
        p1_elo: "#{p1_elo}→#{new_p1_elo}",
        p2_elo: "#{p2_elo}→#{new_p2_elo}",
        result: result
      )

      {p1_out, p2_out}
    end)
  end

  # ── Inactivity decay ───────────────────────────────────────────────────────

  @doc """
  Apply one-tier inactivity decay to all players inactive for 30+ days.
  Run this nightly via InactivityDecayWorker.
  Decay is tracked in rank_history; it does not alter ELO directly.
  """
  def apply_inactivity_decay_all do
    cutoff = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

    User
    |> where([u], not is_nil(u.last_active_at) and u.last_active_at < ^cutoff)
    |> Repo.all()
    |> Enum.each(fn user ->
      Enum.each(["chess", "morris"], fn game_type ->
        {elo, games} = player_stats(user, game_type)
        current_rank = calculate_rank(elo, games, game_type)
        if current_rank do
          level = rank_level(current_rank)
          if level > 1 do
            decayed = rank_at_level(level - 1).name
            record_rank_change(user.id, game_type, current_rank, decayed, "inactivity")
          end
        end
      end)
    end)
  end

  # ── Public helpers ─────────────────────────────────────────────────────────

  @doc "Player ELO and games_played for a given game_type."
  def player_stats(user, "chess"),  do: {user.elo_chess  || 1200, user.games_played_chess  || 0}
  def player_stats(user, "morris"), do: {user.elo_morris || 1200, user.games_played_morris || 0}
  def player_stats(user, _),        do: {user.elo_chess  || 1200, user.games_played_chess  || 0}

  @doc "Serialisable rank summary for a user + game_type (used in JSON responses)."
  def rank_summary(user, game_type) do
    {elo, games} = player_stats(user, game_type)
    rank_name    = calculate_rank(elo, games, game_type)
    rank_info    = if rank_name, do: find_rank(rank_name), else: nil
    next_info    = next_rank_info(rank_name)

    %{
      game_type:          game_type,
      elo:                elo,
      games_played:       games,
      rank:               rank_name,
      rank_emoji:         if(rank_info, do: rank_info.emoji),
      platform_cut:       get_platform_cut(rank_name),
      max_entry_fee_kes:  get_max_entry_fee(rank_name),
      next_rank:          if(next_info, do: next_info.name),
      elo_to_next:        elo_gap_to_next(elo, rank_name),
      games_to_next:      games_gap_to_next(games, rank_name),
    }
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp result_score(:win),  do: 1.0
  defp result_score(:loss), do: 0.0
  defp result_score(:draw), do: 0.5

  defp split_result("white_wins"), do: {:win,  :loss}
  defp split_result("black_wins"), do: {:loss, :win}
  defp split_result(_),            do: {:draw, :draw}

  defp elo_to_level(elo) do
    @ranks
    |> Enum.filter(&(elo >= &1.elo_min))
    |> Enum.max_by(& &1.level)
    |> Map.get(:level)
  end

  defp games_to_level(games) do
    @ranks
    |> Enum.filter(&(games >= &1.games_min))
    |> Enum.max_by(& &1.level)
    |> Map.get(:level)
  end

  defp rank_at_level(level) do
    Enum.find(@ranks, &(&1.level == level)) || hd(@ranks)
  end

  defp rank_level(nil), do: 0
  defp rank_level(name) do
    case find_rank(name) do
      nil  -> 0
      rank -> rank.level
    end
  end

  defp next_rank_info(nil), do: Enum.find(@ranks, &(&1.level == 2))
  defp next_rank_info(name) do
    case find_rank(name) do
      %{level: 8} -> nil
      %{level: l} -> rank_at_level(l + 1)
      nil         -> nil
    end
  end

  defp elo_gap_to_next(elo, rank_name) do
    case next_rank_info(rank_name) do
      nil  -> 0
      next -> max(0, next.elo_min - elo)
    end
  end

  defp games_gap_to_next(games, rank_name) do
    case next_rank_info(rank_name) do
      nil  -> 0
      next -> max(0, next.games_min - games)
    end
  end

  defp apply_stats_changeset(user, "chess", elo, games) do
    Ecto.Changeset.change(user,
      elo_chess:          elo,
      games_played_chess: games,
      last_active_at:     DateTime.utc_now() |> DateTime.truncate(:second)
    )
  end
  defp apply_stats_changeset(user, "morris", elo, games) do
    Ecto.Changeset.change(user,
      elo_morris:          elo,
      games_played_morris: games,
      last_active_at:      DateTime.utc_now() |> DateTime.truncate(:second)
    )
  end
  defp apply_stats_changeset(user, _game_type, elo, games) do
    apply_stats_changeset(user, "chess", elo, games)
  end

  defp record_rank_change(user_id, game_type, old_rank, new_rank, reason) do
    %RankHistory{}
    |> RankHistory.changeset(%{
      user_id:   user_id,
      game_type: game_type,
      old_rank:  old_rank  || "Unranked",
      new_rank:  new_rank  || "Unranked",
      reason:    reason
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  defp to_decimal(v) when is_binary(v), do: Decimal.new(v)
  defp to_decimal(v), do: Decimal.new("#{v}")

  defp in_god_mode_percentile?(elo, game_type) do
    col = case game_type do
      "chess"  -> :elo_chess
      "morris" -> :elo_morris
      _        -> :elo_chess
    end

    total_active = User
      |> where([u], not is_nil(u.last_active_at) and
                    u.last_active_at > ^DateTime.add(DateTime.utc_now(), -90 * 86_400, :second))
      |> Repo.aggregate(:count)

    if total_active < 10 do
      # Not enough players to enforce percentile
      true
    else
      threshold_rank = max(1, round(total_active * @god_mode_top_percentile))
      rank_of_player =
        User
        |> where([u], field(u, ^col) > ^elo)
        |> Repo.aggregate(:count)

      rank_of_player < threshold_rank
    end
  end
end
