defmodule Vector.Repo.Migrations.CreateTournaments do
  use Ecto.Migration

  def change do
    create table(:tournaments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :creator_id, references(:users, type: :binary_id, on_delete: :nothing), null: false
      add :winner_id, references(:users, type: :binary_id, on_delete: :nothing)
      add :game_type, :string, null: false
      add :name, :string, null: false
      add :entry_fee, :decimal, null: false, precision: 12, scale: 2
      add :prize_pool, :decimal, null: false, default: 0, precision: 12, scale: 2
      add :status, :string, null: false, default: "pending"
      add :max_players, :integer, null: false, default: 2
      add :invite_code, :string
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:tournaments, [:creator_id])
    create index(:tournaments, [:status])
    create unique_index(:tournaments, [:invite_code])
  end
end
