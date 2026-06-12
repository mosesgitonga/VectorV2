defmodule Vector.Repo.Migrations.AddTermsFieldsToTournamentParticipants do
  use Ecto.Migration

  def change do
    alter table(:tournament_participants) do
      add :terms_accepted, :boolean, default: false, null: false
      add :terms_accepted_at, :utc_datetime
      add :terms_version, :string
    end
  end
end
