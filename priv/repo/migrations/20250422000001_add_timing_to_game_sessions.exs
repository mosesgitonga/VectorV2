defmodule Vector.Repo.Migrations.AddTimingToGameSessions do
  use Ecto.Migration

  def change do
    alter table(:game_sessions) do
      # Per-player remaining time in milliseconds (default 30 minutes)
      add :white_time_ms, :integer, default: 1_800_000
      add :black_time_ms, :integer, default: 1_800_000
      # When the current player's turn started (for server-side elapsed calculation)
      add :turn_started_at, :utc_datetime_usec
      # Human-readable reason for game ending
      add :result_reason, :string
    end
  end
end
