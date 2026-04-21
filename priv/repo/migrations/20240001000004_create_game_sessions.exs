defmodule Vector.Repo.Migrations.CreateGameSessions do
  use Ecto.Migration

  def change do
    create table(:game_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tournament_id, references(:tournaments, type: :binary_id, on_delete: :nothing), null: false
      add :player_one_id, references(:users, type: :binary_id, on_delete: :nothing), null: false
      add :player_two_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :winner_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :game_type, :string, null: false
      add :status, :string, null: false, default: "waiting"
      add :state, :map, null: false, default: %{}
      add :move_history, {:array, :map}, null: false, default: []
      add :current_turn, :string
      add :result, :string
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:game_sessions, [:tournament_id])
    create index(:game_sessions, [:player_one_id])
    create index(:game_sessions, [:player_two_id])
    create index(:game_sessions, [:status])
  end
end
