defmodule ApiGatewayWeb.Router do
  use ApiGatewayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :otp_request_rate_limited do
    plug ApiGatewayWeb.Plugs.RateLimit, limit: 3, window_seconds: 60
  end

  pipeline :admin_required do
    plug ApiGatewayWeb.Plugs.RequireAdmin
  end

  scope "/", ApiGatewayWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end

  scope "/api/v1/auth", ApiGatewayWeb do
    pipe_through :api

    post "/otp/verify", AuthController, :verify_otp
    post "/refresh", AuthController, :refresh
    post "/logout", AuthController, :logout
    get "/session", AuthController, :session
  end

  scope "/api/v1/auth", ApiGatewayWeb do
    pipe_through [:api, :otp_request_rate_limited]

    post "/otp/request", AuthController, :request_otp
  end

  scope "/api/v1/users", ApiGatewayWeb do
    pipe_through :api

    get "/me", UserController, :me
    patch "/me", UserController, :update_me
    get "/:user_id/profile", UserController, :profile
  end

  scope "/api/v1/conversations", ApiGatewayWeb do
    pipe_through :api

    post "/", ConversationController, :create
    get "/", ConversationController, :index
    get "/:conversation_id", ConversationController, :show
    post "/:conversation_id/participants", ConversationController, :add_participant
    delete "/:conversation_id/participants/:user_id", ConversationController, :remove_participant
  end

  scope "/api/v1/conversations/:conversation_id/messages", ApiGatewayWeb do
    pipe_through :api

    post "/", MessageController, :create
    get "/", MessageController, :index
    patch "/:message_id", MessageController, :update
    delete "/:message_id", MessageController, :delete
    post "/:message_id/read", MessageController, :read
    post "/:message_id/delivered", MessageController, :delivered
    post "/:message_id/reactions", MessageController, :react
    delete "/:message_id/reactions", MessageController, :unreact
    post "/:message_id/star", MessageController, :star
    delete "/:message_id/star", MessageController, :unstar
  end

  scope "/api/v1/starred", ApiGatewayWeb do
    pipe_through :api

    get "/", StarredController, :index
  end

  scope "/api/v1/search", ApiGatewayWeb do
    pipe_through :api

    get "/messages", SearchController, :messages
  end

  scope "/api/v1/media", ApiGatewayWeb do
    pipe_through :api

    post "/uploads", MediaController, :create_upload
    post "/uploads/:media_id/complete", MediaController, :complete_upload
    get "/:media_id/download", MediaController, :download
  end

  # Admin surface — gated by RequireAdmin (403 for non-admins). Phase 0 ships only the smoke endpoints;
  # analytics/moderation/health controllers slot under this same scope in later phases.
  scope "/api/v1/admin", ApiGatewayWeb do
    pipe_through [:api, :admin_required]

    get "/ping", AdminController, :ping
    get "/me", AdminController, :me

    get "/analytics/overview", AdminAnalyticsController, :overview
    get "/analytics/timeseries", AdminAnalyticsController, :timeseries

    get "/users", AdminModerationController, :list_users
    get "/users/:id", AdminModerationController, :get_user
    post "/users/:id/suspend", AdminModerationController, :suspend_user
    post "/users/:id/reactivate", AdminModerationController, :reactivate_user
    post "/users/:id/ban", AdminModerationController, :ban_user

    delete "/messages/:id", AdminModerationController, :delete_message

    get "/reports", AdminModerationController, :list_reports
    post "/reports/:id/status", AdminModerationController, :update_report

    get "/audit", AdminModerationController, :list_audit

    get "/health", AdminHealthController, :show
  end
end
