defmodule Vector.Payments.Transaction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(entry_fee payout refund)
  @statuses ~w(pending success failed refunded)

  schema "transactions" do
    field :type, :string
    field :amount, :decimal
    field :status, :string, default: "pending"
    field :paystack_reference, :string
    field :paystack_access_code, :string
    field :metadata, :map, default: %{}

    belongs_to :user, Vector.Accounts.User
    belongs_to :tournament, Vector.Tournaments.Tournament

    timestamps(type: :utc_datetime)
  end

  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [:user_id, :tournament_id, :type, :amount, :paystack_reference,
                    :paystack_access_code, :metadata])
    |> validate_required([:user_id, :type, :amount])
    |> validate_inclusion(:type, @types)
    |> validate_number(:amount, greater_than: 0)
    |> unique_constraint(:paystack_reference)
  end

  def confirm_changeset(transaction, reference) do
    change(transaction, status: "success", paystack_reference: reference)
  end

  def fail_changeset(transaction) do
    change(transaction, status: "failed")
  end

  def refund_changeset(transaction) do
    change(transaction, status: "refunded")
  end

  def types, do: @types
  def statuses, do: @statuses
end
