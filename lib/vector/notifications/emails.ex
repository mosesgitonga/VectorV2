defmodule Vector.Notifications.Emails do
  import Swoosh.Email

  @from_email {"Vector Games", "no-reply@vectorgames.com"}

  def confirmation_email(user, token) do
    confirm_url = "#{app_url()}/confirm-email?token=#{token}"

    new()
    |> to({user.name, user.email})
    |> from(@from_email)
    |> subject("Confirm your Vector Games account")
    |> html_body("""
    <h2>Welcome to Vector Games, #{user.name}!</h2>
    <p>Please confirm your email address by clicking the link below:</p>
    <p><a href="#{confirm_url}" style="padding:12px 24px;background:#6366f1;color:white;border-radius:6px;text-decoration:none;">Confirm Email</a></p>
    <p>This link expires in 24 hours.</p>
    <p>If you didn't create this account, you can safely ignore this email.</p>
    """)
    |> text_body("Confirm your email: #{confirm_url}")
  end

  def password_reset_email(user, token) do
    reset_url = "#{app_url()}/reset-password?token=#{token}"

    new()
    |> to({user.name, user.email})
    |> from(@from_email)
    |> subject("Reset your Vector Games password")
    |> html_body("""
    <h2>Password Reset Request</h2>
    <p>Hi #{user.name},</p>
    <p>Click the link below to reset your password:</p>
    <p><a href="#{reset_url}" style="padding:12px 24px;background:#6366f1;color:white;border-radius:6px;text-decoration:none;">Reset Password</a></p>
    <p>This link expires in 24 hours. If you didn't request a password reset, ignore this email.</p>
    """)
    |> text_body("Reset your password: #{reset_url}")
  end

  def tournament_invite_email(invitee_email, tournament, invite_url) do
    new()
    |> to(invitee_email)
    |> from(@from_email)
    |> subject("You've been invited to a #{tournament.game_type} tournament!")
    |> html_body("""
    <h2>Tournament Invitation</h2>
    <p>You've been invited to play <strong>#{tournament.name}</strong>.</p>
    <ul>
      <li>Game: #{String.capitalize(tournament.game_type)}</li>
      <li>Entry Fee: KES #{tournament.entry_fee}</li>
      <li>Prize (85%): KES #{Vector.Tournaments.Tournament.prize_amount(tournament)}</li>
    </ul>
    <p><a href="#{invite_url}" style="padding:12px 24px;background:#6366f1;color:white;border-radius:6px;text-decoration:none;">Join Tournament</a></p>
    """)
    |> text_body("Join tournament: #{invite_url}")
  end

  def game_started_email(user, tournament, session_id) do
    game_url = "#{app_url()}/game/#{session_id}"

    new()
    |> to({user.name, user.email})
    |> from(@from_email)
    |> subject("Your #{tournament.game_type} game has started!")
    |> html_body("""
    <h2>Game On!</h2>
    <p>Hi #{user.name}, your tournament game is ready.</p>
    <p>Tournament: <strong>#{tournament.name}</strong></p>
    <p><a href="#{game_url}" style="padding:12px 24px;background:#22c55e;color:white;border-radius:6px;text-decoration:none;">Play Now</a></p>
    """)
    |> text_body("Play your game: #{game_url}")
  end

  def game_result_email(user, tournament, won) do
    result_text = if won, do: "Congratulations, you won!", else: "Better luck next time."
    prize = if won, do: "You'll receive KES #{Vector.Tournaments.Tournament.prize_amount(tournament)} within 24 hours.", else: ""

    new()
    |> to({user.name, user.email})
    |> from(@from_email)
    |> subject("Tournament Result — #{tournament.name}")
    |> html_body("""
    <h2>Game Over</h2>
    <p>Hi #{user.name},</p>
    <p>#{result_text}</p>
    <p>#{prize}</p>
    <p>Tournament: #{tournament.name}</p>
    """)
    |> text_body("#{result_text} #{prize}")
  end

  defp app_url do
    Application.get_env(:vector, :app_url, "http://localhost:3000")
  end
end
