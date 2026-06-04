defmodule Vector.Repo.Migrations.AddStatusCheckConstraints do
  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE tournaments
      ADD CONSTRAINT tournaments_status_check
      CHECK (status IN ('pending','active','finished','cancelled'));
    """

    execute """
    ALTER TABLE game_sessions
      ADD CONSTRAINT game_sessions_status_check
      CHECK (status IN ('waiting','active','finished','abandoned'));
    """
  end

  def down do
    execute "ALTER TABLE tournaments DROP CONSTRAINT IF EXISTS tournaments_status_check;"
    execute "ALTER TABLE game_sessions DROP CONSTRAINT IF EXISTS game_sessions_status_check;"
  end
end
