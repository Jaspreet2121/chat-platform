defmodule ApiGatewayWeb.Router do
  use ApiGatewayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :otp_request_rate_limited do
    plug ApiGatewayWeb.Plugs.RateLimit, limit: 3, window_seconds: 60
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
  end

  scope "/api/v1/media", ApiGatewayWeb do
    pipe_through :api

    post "/uploads", MediaController, :create_upload
    post "/uploads/:media_id/complete", MediaController, :complete_upload
    get "/:media_id/download", MediaController, :download
  end
end
