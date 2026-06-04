defmodule Vector.Repo.Migrations.CreateRankHistories do
  use Ecto.Migration

  def change do
    create table(:rank_histories, primary_key: false) do
      add :id,        :binary_id, primary_key: true
      add :user_id,   references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :game_type, :string, null: false
      add :old_rank,  :string, null: false
      add :new_rank,  :string, null: false
      add :reason,    :string, null: false   # elo_change | inactivity | god_mode_slot
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:rank_histories, [:user_id])
    create index(:rank_histories, [:user_id, :game_type])
  end
end
