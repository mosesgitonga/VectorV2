defmodule Vector.Repo.Migrations.AddEloToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :elo_chess,          :integer, default: 1200, null: false
      add :elo_morris,         :integer, default: 1200, null: false
      add :games_played_chess, :integer, default: 0,    null: false
      add :games_played_morris,:integer, default: 0,    null: false
      add :last_active_at,     :utc_datetime
    end

    create index(:users, [:elo_chess])
    create index(:users, [:elo_morris])
  end
end
