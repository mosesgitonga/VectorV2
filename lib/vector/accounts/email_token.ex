defmodule Vector.Accounts.EmailToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @confirm_validity_days 1
  @reset_validity_days 1

  schema "email_tokens" do
    field :token, :string
    field :context, :string
    field :sent_to, :string
    field :expires_at, :utc_datetime

    belongs_to :user, Vector.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:user_id, :token, :context, :sent_to, :expires_at])
    |> validate_required([:user_id, :token, :context, :sent_to, :expires_at])
    |> unique_constraint([:token, :context])
  end

  def build_email_token(user, context) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    validity =
      case context do
        "confirm" -> @confirm_validity_days
        "reset_password" -> @reset_validity_days
        _ -> 1
      end

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(validity * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    %__MODULE__{}
    |> changeset(%{
      user_id: user.id,
      token: token,
      context: context,
      sent_to: user.email,
      expires_at: expires_at
    })
  end
end
