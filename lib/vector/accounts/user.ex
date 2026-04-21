defmodule Vector.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :email, :string
    field :name, :string
    field :avatar_url, :string
    field :google_id, :string
    field :password, :string, virtual: true
    field :password_hash, :string
    field :role, :string, default: "player"
    field :email_confirmed, :boolean, default: false
    field :balance, :decimal, default: 0
    field :is_active, :boolean, default: true

    has_many :email_tokens, Vector.Accounts.EmailToken
    has_many :created_tournaments, Vector.Tournaments.Tournament, foreign_key: :creator_id
    has_many :tournament_participants, Vector.Tournaments.TournamentParticipant
    has_many :transactions, Vector.Payments.Transaction

    timestamps(type: :utc_datetime)
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :password])
    |> validate_required([:email, :name, :password])
    |> validate_email()
    |> validate_length(:password, min: 8)
    |> hash_password()
  end

  def google_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :google_id, :avatar_url, :email_confirmed])
    |> validate_required([:email, :name, :google_id])
    |> validate_email()
    |> put_change(:email_confirmed, true)
  end

  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :avatar_url])
    |> validate_required([:name])
  end

  def confirm_email_changeset(user) do
    change(user, email_confirmed: true)
  end

  def admin_changeset(user, attrs) do
    user
    |> cast(attrs, [:role, :is_active])
    |> validate_inclusion(:role, ["player", "admin"])
  end

  defp validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, Vector.Repo)
    |> unique_constraint(:email)
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(password))
    end
  end
end
