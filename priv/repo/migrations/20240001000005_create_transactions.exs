defmodule Vector.Repo.Migrations.CreateTransactions do
  use Ecto.Migration

  def change do
    create table(:transactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :nothing), null: false
      add :tournament_id, references(:tournaments, type: :binary_id, on_delete: :nothing)
      add :type, :string, null: false
      add :amount, :decimal, null: false, precision: 12, scale: 2
      add :status, :string, null: false, default: "pending"
      add :paystack_reference, :string
      add :paystack_access_code, :string
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:transactions, [:user_id])
    create index(:transactions, [:tournament_id])
    create index(:transactions, [:status])
    create unique_index(:transactions, [:paystack_reference])
  end
end
