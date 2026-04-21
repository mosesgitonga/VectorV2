alias Vector.Accounts
alias Vector.Repo

case Accounts.get_user_by_email("admin@vectorgames.com") do
  nil ->
    {:ok, _} =
      Accounts.register_user(%{
        email: "admin@vectorgames.com",
        name: "Admin",
        password: "admin1234"
      })

    Accounts.get_user_by_email("admin@vectorgames.com")
    |> Vector.Accounts.User.admin_changeset(%{role: "admin", email_confirmed: true})
    |> Repo.update!()

    IO.puts("Admin created: admin@vectorgames.com / admin1234")

  _ ->
    IO.puts("Admin already exists")
end
