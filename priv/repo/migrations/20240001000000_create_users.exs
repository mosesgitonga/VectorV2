defmodule Vector.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :name, :string, null: false
      add :avatar_url, :string
      add :google_id, :string
      add :password_hash, :string
      add :role, :string, null: false, default: "player"
      add :email_confirmed, :boolean, null: false, default: false
      add :balance, :decimal, null: false, default: 0, precision: 12, scale: 2
      add :is_active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:google_id])
    create index(:users, [:role])
  end
end
