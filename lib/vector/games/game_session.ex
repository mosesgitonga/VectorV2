defmodule Vector.Games.GameSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(waiting active finished abandoned)
  @game_types ~w(chess morris)

  schema "game_sessions" do
    field :game_type, :string
    field :status, :string, default: "waiting"
    field :state, :map, default: %{}
    field :move_history, {:array, :map}, default: []
    field :current_turn, :string
    field :result, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :tournament, Vector.Tournaments.Tournament
    belongs_to :player_one, Vector.Accounts.User
    belongs_to :player_two, Vector.Accounts.User
    belongs_to :winner, Vector.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def create_changeset(session, attrs) do
    session
    |> cast(attrs, [:tournament_id, :player_one_id, :player_two_id, :game_type, :state, :current_turn])
    |> validate_required([:tournament_id, :player_one_id, :game_type])
    |> validate_inclusion(:game_type, @game_types)
    |> put_change(:status, "waiting")
  end

  def start_changeset(session, state) do
    session
    |> change(status: "active", state: state, started_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  def move_changeset(session, new_state, move, next_turn) do
    history = (session.move_history || []) ++ [move]

    session
    |> change(state: new_state, move_history: history, current_turn: next_turn)
  end

  def finish_changeset(session, winner_id, result) do
    session
    |> change(
      status: "finished",
      winner_id: winner_id,
      result: result,
      current_turn: nil,
      finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
  end

  def abandon_changeset(session) do
    session
    |> change(status: "abandoned", finished_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  def statuses, do: @statuses
  def game_types, do: @game_types
end
