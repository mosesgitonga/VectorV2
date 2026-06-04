defmodule Vector.Repo.Migrations.AddPlatformCutToTournaments do
  use Ecto.Migration

  def change do
    alter table(:tournaments) do
      # Stored when second player joins, based on lower-ranked player's cut.
      # Defaults to 0.15 (Knight / baseline) until both players are known.
      add :platform_cut_percent, :decimal, precision: 6, scale: 4, default: "0.1500"
    end
  end
end
