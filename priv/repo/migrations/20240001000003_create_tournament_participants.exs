defmodule Vector.Repo.Migrations.CreateTournamentParticipants do
  use Ecto.Migration

  def change do
    create table(:tournament_participants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tournament_id, references(:tournaments, type: :binary_id, on_delete: :delete_all), null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :paid_at, :utc_datetime
      add :seat, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tournament_participants, [:tournament_id, :user_id])
    create index(:tournament_participants, [:user_id])
  end
end
