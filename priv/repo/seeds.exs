alias Vector.Accounts
alias Vector.Repo

# Admin credentials must be set via environment variables — never hardcoded.
# Set SEED_ADMIN_EMAIL and SEED_ADMIN_PASSWORD before running seeds.
admin_email    = System.get_env("SEED_ADMIN_EMAIL")
admin_password = System.get_env("SEED_ADMIN_PASSWORD")

if is_nil(admin_email) or is_nil(admin_password) do
  IO.puts("Skipping admin seed — SEED_ADMIN_EMAIL / SEED_ADMIN_PASSWORD not set.")
else
  case Accounts.get_user_by_email(admin_email) do
    nil ->
      {:ok, _} =
        Accounts.register_user(%{
          email: admin_email,
          name: "Admin",
          password: admin_password
        })

      Accounts.get_user_by_email(admin_email)
      |> Vector.Accounts.User.admin_changeset(%{role: "admin", email_confirmed: true})
      |> Repo.update!()

      IO.puts("Admin created: #{admin_email}")

    _ ->
      IO.puts("Admin already exists: #{admin_email}")
  end
end
