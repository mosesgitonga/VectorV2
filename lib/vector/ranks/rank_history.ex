defmodule Vector.Ranks.RankHistory do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @reasons ~w(elo_change inactivity god_mode_slot)

  schema "rank_histories" do
    field :game_type, :string
    field :old_rank,  :string
    field :new_rank,  :string
    field :reason,    :string

    belongs_to :user, Vector.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(rh, attrs) do
    rh
    |> cast(attrs, [:user_id, :game_type, :old_rank, :new_rank, :reason])
    |> validate_required([:user_id, :game_type, :old_rank, :new_rank, :reason])
    |> validate_inclusion(:reason, @reasons)
  end
end
