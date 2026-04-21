defmodule Vector.Tournaments.Tournament do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending active finished cancelled)
  @game_types ~w(chess morris)
  @payout_percentage Decimal.new("0.85")

  schema "tournaments" do
    field :name, :string
    field :game_type, :string
    field :entry_fee, :decimal
    field :prize_pool, :decimal, default: 0
    field :status, :string, default: "pending"
    field :max_players, :integer, default: 2
    field :invite_code, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :creator, Vector.Accounts.User
    belongs_to :winner, Vector.Accounts.User

    has_many :participants, Vector.Tournaments.TournamentParticipant
    has_many :game_sessions, Vector.Games.GameSession

    timestamps(type: :utc_datetime)
  end

  def create_changeset(tournament, attrs) do
    tournament
    |> cast(attrs, [:name, :game_type, :entry_fee, :max_players, :creator_id])
    |> validate_required([:name, :game_type, :entry_fee, :creator_id])
    |> validate_inclusion(:game_type, @game_types)
    |> validate_number(:entry_fee, greater_than: 0)
    |> validate_number(:max_players, equal_to: 2)
    |> put_change(:status, "pending")
    |> put_invite_code()
  end

  def start_changeset(tournament) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(tournament, status: "active", started_at: now)
  end

  def finish_changeset(tournament, winner_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(tournament, status: "finished", winner_id: winner_id, finished_at: now)
  end

  def cancel_changeset(tournament) do
    change(tournament, status: "cancelled")
  end

  def prize_amount(%__MODULE__{prize_pool: pool}) do
    Decimal.mult(pool, @payout_percentage)
  end

  def statuses, do: @statuses

  defp put_invite_code(changeset) do
    code = :crypto.strong_rand_bytes(4) |> Base.url_encode64(padding: false)
    put_change(changeset, :invite_code, code)
  end
end
