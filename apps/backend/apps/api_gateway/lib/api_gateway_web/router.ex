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

  # Public integrator API: authenticate (secret key OR end-user JWT) → app_id scope → per-app rate limit.
  pipeline :v1 do
    plug :accepts, ["json"]
    # FIRST: registers a before_send so it observes EVERY /v1 response — incl. 401/429 halts below.
    plug ApiGatewayWeb.Plugs.Observability
    plug ApiGatewayWeb.Plugs.V1Auth
    plug ApiGatewayWeb.Plugs.V1RateLimit
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

  # App-owner management of secret API keys (logged-in app session; key's app = session app_id).
  # Public, versioned integrator API — separate from the existing app's /api/v1 internal routes.
  scope "/v1", ApiGatewayWeb.V1 do
    pipe_through :v1

    post "/auth/token", AuthController, :token
    post "/conversations", ConversationController, :create
    get "/conversations", ConversationController, :index
    get "/conversations/:id", ConversationController, :show
    post "/conversations/:id/messages", MessageController, :create
    get "/conversations/:id/messages", MessageController, :index

    # End-user call surface for integrator SDKs (end-user JWT actor required; a secret-key actor → 403
    # v1.end_user_only). Scoped to the caller's app: calls/links carry no app_id, so scope rides on
    # app-scoped user_ids (seat membership for calls, creator for links). Users are referred to by the
    # integrator's external_id in and out.
    post "/calls", CallController, :create
    post "/calls/:id/token", CallController, :token
    post "/calls/:id/end", CallController, :end_call
    get "/calls/:id", CallController, :show
    post "/call-links", CallController, :create_link
    post "/call-links/:id/join", CallController, :join_link
    get "/call-links/:id", CallController, :show_link

    # Key-authenticated webhook management for integrator servers (app_id = the key's app; secret-key
    # actor required). Same Webhooks context as the session route below.
    post "/webhooks/endpoints", WebhookEndpointController, :create
    get "/webhooks/endpoints", WebhookEndpointController, :index
    patch "/webhooks/endpoints/:id", WebhookEndpointController, :update
    delete "/webhooks/endpoints/:id", WebhookEndpointController, :delete
  end

  # Self-serve integrator onboarding — register a business app (distinct live app_id) + list owned apps.
  scope "/api/v1/apps", ApiGatewayWeb do
    pipe_through :api

    post "/", AppController, :create
    get "/", AppController, :index
  end

  scope "/api/v1/api-keys", ApiGatewayWeb do
    pipe_through :api

    post "/", ApiKeyController, :create
    get "/", ApiKeyController, :index
    delete "/:id", ApiKeyController, :revoke
  end

  # App-owner management of webhook endpoints (logged-in app session; endpoint app = session app_id).
  scope "/api/v1/webhooks/endpoints", ApiGatewayWeb do
    pipe_through :api

    post "/", WebhookEndpointController, :create
    get "/", WebhookEndpointController, :index
    patch "/:id", WebhookEndpointController, :update
    delete "/:id", WebhookEndpointController, :delete
  end

  scope "/api/v1/users", ApiGatewayWeb do
    pipe_through :api

    get "/me", UserController, :me
    patch "/me", UserController, :update_me

    # Phone → profile lookup for direct chat (session-gated in the controller). A literal one-segment
    # path, so it never collides with the two-segment "/:user_id/profile" below.
    get "/by-phone", UserController, :by_phone
    get "/:user_id/profile", UserController, :profile
    # Direct-peer contact info (phone) — server-verified shared-direct-conversation scope.
    get "/:user_id/peer-contact", UserController, :peer_contact
    # PUBLIC avatar proxy (stable URL → 302 to a fresh presign) — for web-push notification icons.
    get "/:user_id/avatar", UserController, :avatar
  end

  # WhatsApp-style invites: mint an invite code for a non-platform phone number (session-authed).
  # Sending happens on the user's device (wa.me / sms: URL schemes) — no send API here.
  scope "/api/v1/invites", ApiGatewayWeb do
    pipe_through :api

    post "/", InviteController, :create
  end

  # Web-push subscription registration (session-gated; upsert/delete the caller's own browser).
  scope "/api/v1/push", ApiGatewayWeb do
    pipe_through :api

    post "/subscriptions", PushController, :create
    delete "/subscriptions", PushController, :delete
  end

  # Phase-1 calling — LiveKit access token (session-gated in the controller). Slice 1 takes a room name
  # directly; call-row validation is a later slice.
  scope "/api/v1/calls", ApiGatewayWeb do
    pipe_through :api

    # Call history for the authenticated user (both sides), newest first — Slice-5a.
    get "/", CallController, :index
    post "/token", CallController, :token
  end

  # Call links (L1) — reusable link → conversation-less "link" call. Registered users only (session-gated in
  # the controller). Join returns a room; the client fetches a token via /api/v1/calls/token.
  scope "/api/v1/call-links", ApiGatewayWeb do
    pipe_through :api

    post "/", CallLinkController, :create
    get "/:id", CallLinkController, :show
    post "/:id/join", CallLinkController, :join
  end

  scope "/api/v1/conversations", ApiGatewayWeb do
    pipe_through :api

    post "/", ConversationController, :create
    get "/", ConversationController, :index
    get "/:conversation_id", ConversationController, :show
    # Ongoing group call (for the "join call" banner) — membership-gated (Slice C1).
    get "/:conversation_id/ongoing-call", ConversationController, :ongoing_call
    post "/:conversation_id/participants", ConversationController, :add_participant
    # User-scoped soft-hides (nothing deleted; admin content viewer unaffected).
    post "/:conversation_id/clear", ConversationController, :clear
    # Shared-media gallery (membership-gated filtered read).
    get "/:conversation_id/media", MessageController, :media
    put "/:conversation_id/auto-delete", ConversationController, :auto_delete
    put "/:conversation_id/mute", ConversationController, :mute
    # Group name/photo (owner-gated in the conversation service).
    put "/:conversation_id/group-profile", ConversationController, :group_profile
    delete "/:conversation_id/participants/:user_id", ConversationController, :remove_participant
    # Group admin: promote/demote (owner-only) + only-admins-can-send toggle (owner/admin).
    put "/:conversation_id/participants/:user_id/role", ConversationController, :set_participant_role
    put "/:conversation_id/settings", ConversationController, :set_group_settings
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
    post "/users/:id/role", AdminModerationController, :set_user_role
    delete "/users/:id", AdminModerationController, :delete_user

    delete "/messages/:id", AdminModerationController, :delete_message

    # IAM Phase 2 — admin content-access (oversight). Entry = console access; the controller returns FULL
    # content only for content.read (root) and audits every unmasked read, else MASKED metadata.
    get "/conversations", AdminContentController, :conversations
    get "/users/:id/conversations", AdminContentController, :user_conversations
    get "/conversations/:id/messages", AdminContentController, :messages

    get "/reports", AdminModerationController, :list_reports
    post "/reports/:id/status", AdminModerationController, :update_report

    get "/audit", AdminModerationController, :list_audit

    # Webhook failed-delivery ops (dead-letter inspection + idempotent / bulk re-enqueue).
    get "/webhooks/outbox/failed", AdminWebhookController, :failed
    post "/webhooks/outbox/:id/reenqueue", AdminWebhookController, :reenqueue
    post "/webhooks/outbox/reenqueue_bulk", AdminWebhookController, :reenqueue_bulk

    get "/health", AdminHealthController, :show

    # Per-app usage metrics (request counts by app+route, webhook deliveries, error counts).
    get "/metrics", AdminMetricsController, :show
  end
end
