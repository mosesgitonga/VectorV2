defmodule Vector.Notifications do
  alias Vector.Notifications.Emails
  alias Vector.Mailer

  def send_confirmation_email(user, token) do
    user
    |> Emails.confirmation_email(token)
    |> Mailer.deliver()
  end

  def send_password_reset_email(user, token) do
    user
    |> Emails.password_reset_email(token)
    |> Mailer.deliver()
  end

  def send_tournament_invite(invitee_email, tournament) do
    invite_url = "#{app_url()}/join/#{tournament.invite_code}"

    tournament
    |> Emails.tournament_invite_email(invitee_email, invite_url)
    |> Mailer.deliver()
  end

  def send_game_started_email(tournament) do
    session = List.first(Vector.Games.list_sessions_for_tournament(tournament.id))

    if session do
      for participant <- tournament.participants do
        user = participant.user
        user |> Emails.game_started_email(tournament, session.id) |> Mailer.deliver()
      end
    end
  end

  def send_game_result_email(tournament, winner_id) do
    for participant <- tournament.participants do
      user = participant.user
      won = user.id == winner_id
      user |> Emails.game_result_email(tournament, won) |> Mailer.deliver()
    end
  end

  defp app_url do
    Application.get_env(:vector, :app_url, "http://localhost:3000")
  end
end
