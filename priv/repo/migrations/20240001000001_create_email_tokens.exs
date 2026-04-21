defmodule Vector.Repo.Migrations.CreateEmailTokens do
  use Ecto.Migration

  def change do
    create table(:email_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :token, :string, null: false
      add :context, :string, null: false
      add :sent_to, :string, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:email_tokens, [:token, :context])
    create index(:email_tokens, [:user_id])
  end
end
