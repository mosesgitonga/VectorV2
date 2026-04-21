defmodule Vector.Accounts do
  import Ecto.Query
  alias Vector.Repo
  alias Vector.Accounts.{User, EmailToken}
  alias Vector.Notifications

  # ── Users ────────────────────────────────────────────────────────────────────

  def get_user(id), do: Repo.get(User, id)

  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_email(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  def get_user_by_google_id(google_id) do
    Repo.get_by(User, google_id: google_id)
  end

  def list_users(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    User
    |> order_by([u], desc: u.inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def count_users do
    Repo.aggregate(User, :count)
  end

  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, user} ->
        send_confirmation_email(user)
        {:ok, user}

      error ->
        error
    end
  end

  def find_or_create_google_user(attrs) do
    case get_user_by_google_id(attrs[:google_id]) do
      %User{} = user ->
        {:ok, user}

      nil ->
        case get_user_by_email(attrs[:email]) do
          %User{} = user ->
            user
            |> User.google_changeset(attrs)
            |> Repo.update()

          nil ->
            %User{}
            |> User.google_changeset(attrs)
            |> Repo.insert()
        end
    end
  end

  def update_user_profile(user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  def authenticate_user(email, password) do
    user = get_user_by_email(email)

    cond do
      is_nil(user) ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}

      not Bcrypt.verify_pass(password, user.password_hash || "") ->
        {:error, :invalid_credentials}

      not user.is_active ->
        {:error, :account_disabled}

      true ->
        {:ok, user}
    end
  end

  # ── Email confirmation ────────────────────────────────────────────────────────

  def send_confirmation_email(user) do
    with {:ok, email_token} <- create_email_token(user, "confirm") do
      Notifications.send_confirmation_email(user, email_token.token)
    end
  end

  def confirm_user_email(token) do
    with {:ok, email_token} <- verify_email_token(token, "confirm"),
         user <- Repo.get!(User, email_token.user_id),
         {:ok, user} <- user |> User.confirm_email_changeset() |> Repo.update() do
      delete_email_tokens(user, "confirm")
      {:ok, user}
    end
  end

  def send_password_reset_email(email) do
    user = get_user_by_email(email)

    if user do
      with {:ok, email_token} <- create_email_token(user, "reset_password") do
        Notifications.send_password_reset_email(user, email_token.token)
      end
    end

    :ok
  end

  def reset_password(token, new_password) do
    with {:ok, email_token} <- verify_email_token(token, "reset_password"),
         user <- Repo.get!(User, email_token.user_id),
         {:ok, user} <-
           user
           |> User.registration_changeset(%{
             email: user.email,
             name: user.name,
             password: new_password
           })
           |> Repo.update() do
      delete_email_tokens(user, "reset_password")
      {:ok, user}
    end
  end

  defp create_email_token(user, context) do
    delete_email_tokens(user, context)

    EmailToken.build_email_token(user, context)
    |> Repo.insert()
  end

  defp verify_email_token(token, context) do
    now = DateTime.utc_now()

    case Repo.get_by(EmailToken, token: token, context: context) do
      nil ->
        {:error, :invalid_token}

      %EmailToken{expires_at: expires_at} when expires_at < now ->
        {:error, :expired_token}

      email_token ->
        {:ok, email_token}
    end
  end

  defp delete_email_tokens(user, context) do
    EmailToken
    |> where(user_id: ^user.id, context: ^context)
    |> Repo.delete_all()
  end
end
