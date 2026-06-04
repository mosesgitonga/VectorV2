defmodule VectorWeb.AuthController do
  use VectorWeb, :controller

  alias Vector.Accounts
  alias Vector.Accounts.Guardian

  # 10 attempts per minute per IP on sensitive endpoints
  @rate_limit_scale_ms 60_000
  @rate_limit_max      10

  # ── Email/password registration ────────────────────────────────────────────

  def register(conn, params) do
    with :ok <- check_rate(conn, "register") do
      case Accounts.register_user(params) do
        {:ok, user} ->
          {:ok, token, _claims} = Guardian.encode_and_sign(user)

          conn
          |> put_status(:created)
          |> json(%{user: user_json(user), token: token,
                     message: "Registration successful. Please confirm your email."})

        {:error, changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: format_errors(changeset)})
      end
    end
  end

  def login(conn, %{"email" => email, "password" => password}) do
    with :ok <- check_rate(conn, "login") do
      case Accounts.authenticate_user(email, password) do
        {:ok, user} ->
          {:ok, token, _claims} = Guardian.encode_and_sign(user)
          json(conn, %{user: user_json(user), token: token})

        {:error, :invalid_credentials} ->
          conn
          |> put_status(:unauthorized)
          |> json(%{error: "Invalid email or password"})

        {:error, :account_disabled} ->
          conn
          |> put_status(:forbidden)
          |> json(%{error: "Account has been disabled"})
      end
    end
  end

  # ── Google OAuth ───────────────────────────────────────────────────────────

  def google_callback(conn, %{"code" => code}) do
    with {:ok, google_user} <- fetch_google_user(code),
         {:ok, user} <- Accounts.find_or_create_google_user(google_user) do
      {:ok, token, _claims} = Guardian.encode_and_sign(user)

      frontend_url = Application.get_env(:vector, :app_url, "http://localhost:3000")
      redirect(conn, external: "#{frontend_url}/auth/callback#token=#{token}")
    else
      {:error, :account_disabled} ->
        frontend_url = Application.get_env(:vector, :app_url, "http://localhost:3000")
        redirect(conn, external: "#{frontend_url}/login?error=account_disabled")

      {:error, _reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Sign-in with Google failed. Please try again."})
    end
  end

  def google_callback(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing code parameter"})
  end

  # ── Email confirmation ─────────────────────────────────────────────────────

  def confirm_email(conn, %{"token" => token}) do
    case Accounts.confirm_user_email(token) do
      {:ok, _user} ->
        json(conn, %{message: "Email confirmed successfully"})

      {:error, :invalid_token} ->
        conn |> put_status(:bad_request) |> json(%{error: "Invalid or expired token"})

      {:error, :expired_token} ->
        conn |> put_status(:bad_request) |> json(%{error: "Token has expired"})
    end
  end

  def resend_confirmation(conn, _params) do
    with :ok <- check_rate(conn, "resend_confirmation") do
      user = conn.assigns.current_user

      if user.email_confirmed do
        conn |> put_status(:bad_request) |> json(%{error: "Email already confirmed"})
      else
        Task.start(fn -> Accounts.send_confirmation_email(user) end)
        json(conn, %{message: "Confirmation email sent"})
      end
    end
  end

  # ── Password reset ─────────────────────────────────────────────────────────

  def forgot_password(conn, %{"email" => email}) do
    with :ok <- check_rate(conn, "forgot_password") do
      Accounts.send_password_reset_email(email)
      json(conn, %{message: "If that email exists, a reset link has been sent"})
    end
  end

  def reset_password(conn, %{"token" => token, "password" => password}) do
    with :ok <- check_rate(conn, "reset_password") do
      case Accounts.reset_password(token, password) do
        {:ok, _user} ->
          json(conn, %{message: "Password reset successfully"})

        {:error, _} ->
          conn |> put_status(:bad_request) |> json(%{error: "Invalid or expired token"})
      end
    end
  end

  def me(conn, _params) do
    json(conn, %{user: user_json(conn.assigns.current_user)})
  end

  def update_phone(conn, %{"phone_number" => phone}) do
    user = conn.assigns.current_user

    case Accounts.update_phone(user, phone) do
      {:ok, updated_user} ->
        json(conn, %{user: user_json(updated_user)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp check_rate(conn, action) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()

    case ExRated.check_rate("#{action}:#{ip}", @rate_limit_scale_ms, @rate_limit_max) do
      {:ok, _count} ->
        :ok

      {:error, _limit} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Too many attempts. Please try again later."})
        |> halt()
        |> then(fn _ -> {:error, :rate_limited} end)
    end
  end

  defp fetch_google_user(code) do
    token_url = "https://oauth2.googleapis.com/token"
    client_id = Application.fetch_env!(:vector, :google_client_id)
    client_secret = Application.fetch_env!(:vector, :google_client_secret)
    redirect_uri = Application.get_env(:vector, :google_redirect_uri)

    body =
      URI.encode_query(%{
        code: code,
        client_id: client_id,
        client_secret: client_secret,
        redirect_uri: redirect_uri,
        grant_type: "authorization_code"
      })

    with {:ok, %{status: 200, body: body}} <-
           Finch.build(:post, token_url, [{"Content-Type", "application/x-www-form-urlencoded"}], body)
           |> Finch.request(Vector.Finch),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, access_token} <- Map.fetch(decoded, "access_token"),
         {:ok, user_info} <- fetch_google_user_info(access_token) do
      {:ok,
       %{
         google_id: user_info["id"],
         email: user_info["email"],
         name: user_info["name"],
         avatar_url: user_info["picture"],
         email_confirmed: true
       }}
    else
      {:ok, %{status: status}} -> {:error, {:token_exchange_failed, status}}
      {:ok, _non_200} -> {:error, :token_exchange_failed}
      :error -> {:error, :missing_access_token}
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json_response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_google_user_info(access_token) do
    url = "https://www.googleapis.com/oauth2/v2/userinfo"
    headers = [{"Authorization", "Bearer #{access_token}"}]

    case Finch.build(:get, url, headers) |> Finch.request(Vector.Finch) do
      {:ok, %{status: 200, body: body}} -> {:ok, Jason.decode!(body)}
      _ -> {:error, :failed_to_fetch_user_info}
    end
  end

  defp user_json(user) do
    %{
      id: user.id,
      email: user.email,
      name: user.name,
      avatar_url: user.avatar_url,
      role: user.role,
      email_confirmed: user.email_confirmed,
      balance: user.balance,
      phone_number: user.phone_number
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end