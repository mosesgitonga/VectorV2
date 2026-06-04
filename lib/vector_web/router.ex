defmodule VectorWeb.Router do
  use VectorWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug VectorWeb.Plugs.AuthPlug
  end

  pipeline :email_confirmed do
    plug VectorWeb.Plugs.EmailConfirmedPlug
  end

  pipeline :admin do
    plug VectorWeb.Plugs.AdminPlug
  end

  # ── Public routes ──────────────────────────────────────────────────────────

  scope "/api/auth", VectorWeb do
    pipe_through :api

    post "/register", AuthController, :register
    post "/login", AuthController, :login
    get "/google/callback", AuthController, :google_callback
    post "/confirm-email", AuthController, :confirm_email
    post "/forgot-password", AuthController, :forgot_password
    post "/reset-password", AuthController, :reset_password
  end

  scope "/api/payments", VectorWeb do
    pipe_through :api
    post "/webhook", PaymentController, :webhook
  end

  # ── Authenticated routes (no email confirmation required) ─────────────────

  scope "/api", VectorWeb do
    pipe_through [:api, :authenticated]

    get "/auth/me", AuthController, :me
    post "/auth/resend-confirmation", AuthController, :resend_confirmation
    put "/auth/phone", AuthController, :update_phone

    get "/users/:id", UserController, :show
    put "/users/me", UserController, :update

    get "/tournaments", TournamentController, :index
    get "/tournaments/mine", TournamentController, :my_tournaments
    get "/tournaments/waiting", TournamentController, :waiting
    get "/tournaments/:id", TournamentController, :show
    get "/tournaments/:id/sessions", TournamentController, :sessions
    post "/tournaments/:id/invite", TournamentController, :invite
    delete "/tournaments/:id", TournamentController, :cancel

    get "/games/active", GameController, :active
    get "/games/:id", GameController, :show

    get "/payments/withdraw/limit", PaymentController, :withdrawal_limit
    get "/payments/transactions", PaymentController, :my_transactions
  end

  # ── Authenticated + email confirmed (financial operations) ─────────────────

  scope "/api", VectorWeb do
    pipe_through [:api, :authenticated, :email_confirmed]

    post "/tournaments", TournamentController, :create
    post "/tournaments/join", TournamentController, :join

    post "/payments/deposit", PaymentController, :deposit
    post "/payments/withdraw", PaymentController, :withdraw
    get "/payments/verify/:reference", PaymentController, :verify
  end

  # ── Admin routes ───────────────────────────────────────────────────────────

  scope "/api/admin", VectorWeb do
    pipe_through [:api, :authenticated, :admin]

    get "/dashboard", AdminController, :dashboard
    get "/users", AdminController, :list_users
    patch "/users/:id", AdminController, :update_user
    get "/tournaments", AdminController, :list_tournaments
    delete "/tournaments/:id", AdminController, :cancel_tournament
    get "/transactions", AdminController, :list_transactions
    get "/revenue", AdminController, :revenue
  end

  # ── Dev routes ─────────────────────────────────────────────────────────────

  if Application.compile_env(:vector, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]
      live_dashboard "/dashboard", metrics: VectorWeb.Telemetry
    end
  end
end
