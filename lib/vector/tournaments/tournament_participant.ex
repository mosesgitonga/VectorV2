defmodule Vector.Tournaments.TournamentParticipant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tournament_participants" do
    field :paid_at, :utc_datetime
    field :seat, :integer

    belongs_to :tournament, Vector.Tournaments.Tournament
    belongs_to :user, Vector.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(participant, attrs) do
    participant
    |> cast(attrs, [:tournament_id, :user_id, :seat])
    |> validate_required([:tournament_id, :user_id])
    |> unique_constraint([:tournament_id, :user_id])
  end

  def paid_changeset(participant) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(participant, paid_at: now)
  end
end
