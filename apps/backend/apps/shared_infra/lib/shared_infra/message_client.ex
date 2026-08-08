defmodule SharedInfra.MessageClient do
  @moduledoc """
  Client boundary for the Message service — lets edge apps (api_gateway, realtime_gateway)
  stop calling `MessageService.*` in-process directly. The heaviest seam (most call-sites,
  both edges).

  Same pattern as the other `SharedInfra.*Client`s: behaviour AND configured dispatcher.
  Adapter from `:shared_infra, :message_client_adapter` (config default
  `MessageService.MessageClientInProcess`, delegates in-process → zero behavior change). A
  future `MESSAGE_CLIENT_ADAPTER=http` selects an HTTP adapter (separate message-service
  container) WITHOUT touching call sites. shared_infra resolves the adapter from config at
  runtime, so it stays free of a service dependency.

  `list_timeline/1` maps to `MessageService.Timeline.list_messages/1` (distinct from
  `MessageService.Messages.list_messages/1`, exposed here as `list_messages/1`).

  ## `get_message/1` is deliberately UNCALLED

  It exists for `notification_service`, whose `PushContext.message_preview_fields/1` reads the
  `messages` table with raw SQL against the shared Postgres. That read returns nothing once the
  message store moves to Scylla, and the push silently degrades to the body "New message" — the
  failure is invisible because it still looks like a working notification.

  Moving that read onto this boundary is NOT enough on its own, and this is the thing nobody had
  written down: the `notification_service` RELEASE bundles only `[shared_infra, notification_service]`
  (`mix.exs`), so `MessageService.MessageClientInProcess` — the default adapter — DOES NOT EXIST in
  that container. The in-process default would raise there. The push body can only move off Postgres
  once the notification container is configured with `MESSAGE_CLIENT_ADAPTER=http` and
  `MESSAGE_SERVICE_URL`, and that is a production topology change with a real trade: today a
  message-service outage leaves push previews working (they read the shared DB directly); afterwards
  every preview during such an outage degrades to "New message".

  So this callback is the capability, added and proven, with no caller. An unused callback is honest;
  a half-wired one is not.
  """

  @type attrs :: map()
  @type result :: {:ok, map()} | {:error, term()}

  @callback create_message(attrs()) :: result()
  @callback send_message(attrs()) :: result()
  @callback list_messages(attrs()) :: result()
  @callback list_timeline(attrs()) :: result()
  @callback update_message(attrs()) :: result()
  @callback edit_message(attrs()) :: result()
  @callback delete_message(attrs()) :: result()
  @callback mark_read(attrs()) :: result()
  @callback mark_delivered(attrs()) :: result()
  @callback analytics_overview(attrs()) :: result()
  @callback analytics_timeseries(attrs()) :: result()
  @callback admin_delete_message(attrs()) :: result()
  @callback add_reaction(attrs()) :: result()
  @callback remove_reaction(attrs()) :: result()
  @callback star_message(attrs()) :: result()
  @callback unstar_message(attrs()) :: result()
  @callback list_starred(attrs()) :: result()
  @callback search_messages(attrs()) :: result()
  @callback pin_message(attrs()) :: result()
  @callback unpin_message(attrs()) :: result()
  @callback list_pins(attrs()) :: result()
  @callback list_media(attrs()) :: result()
  @callback get_by_media_id(attrs()) :: result()
  # Message info (per-user delivery/read state; sender-only). Optional so existing stubs don't all need it.
  @callback message_info(attrs()) :: result()
  # Single message by id, straight off `MessageService.MessageStore` — the ONLY read on this boundary
  # that reaches the store rather than a `Messages`/`Timeline` function, because that is where the
  # store adapter (postgres / scylla / dual-write) is selected. Added for `notification_service`, whose
  # push preview reads `messages` with raw SQL against the shared Postgres and therefore goes blank the
  # moment the store moves to Scylla. NOTHING CALLS IT YET — see the moduledoc note below.
  #
  # NO AUTHORIZATION. `MessageStore.get_message/1` is a raw store read: no viewer window, no
  # `deleted_at`/`cleared_before` filter, no block check. It is safe for the push consumer (which has
  # already decided the recipient set from the conversation's participants) and is NOT safe to expose
  # to a user-facing controller without adding those filters at the caller.
  @callback get_message(attrs()) :: result()
  # Polls: replace-the-set vote + the uncapped voter lists.
  @callback vote_poll(attrs()) :: result()
  @callback list_poll_votes(attrs()) :: result()
  # Status (082): posts, the one-query feed, per-owner list, owner delete, media-authz support.
  @callback post_status(attrs()) :: result()
  @callback status_feed(attrs()) :: result()
  @callback list_status_posts(attrs()) :: result()
  @callback delete_status(attrs()) :: result()
  @callback status_media_allowed(attrs()) :: result()
  # Status commit 2: audience modes + view recording + the owner's viewer lists.
  @callback get_status_audience(attrs()) :: result()
  @callback set_status_audience(attrs()) :: result()
  @callback record_status_view(attrs()) :: result()
  @callback status_viewers(attrs()) :: result()
  @callback my_status(attrs()) :: result()
  # Status commit 3: resolve a status for replying (audience gate at REPLY time + the text snapshot).
  @callback status_for_reply(attrs()) :: result()
  # Owner-anchored message-media download authorization.
  @callback media_download_allowed(attrs()) :: result()
  @optional_callbacks message_info: 1,
                      get_message: 1,
                      media_download_allowed: 1,
                      vote_poll: 1,
                      list_poll_votes: 1,
                      post_status: 1,
                      status_feed: 1,
                      list_status_posts: 1,
                      delete_status: 1,
                      status_media_allowed: 1,
                      get_status_audience: 1,
                      set_status_audience: 1,
                      record_status_view: 1,
                      status_viewers: 1,
                      my_status: 1,
                      status_for_reply: 1

  def create_message(attrs), do: normalize(adapter().create_message(attrs))
  def send_message(attrs), do: normalize(adapter().send_message(attrs))
  def list_messages(attrs), do: normalize(adapter().list_messages(attrs))
  def list_timeline(attrs), do: normalize(adapter().list_timeline(attrs))
  def update_message(attrs), do: normalize(adapter().update_message(attrs))
  def edit_message(attrs), do: normalize(adapter().edit_message(attrs))
  def delete_message(attrs), do: normalize(adapter().delete_message(attrs))
  def mark_read(attrs), do: normalize(adapter().mark_read(attrs))
  def message_info(attrs), do: normalize(adapter().message_info(attrs))
  def get_message(attrs), do: normalize(adapter().get_message(attrs))
  def vote_poll(attrs), do: normalize(adapter().vote_poll(attrs))
  def list_poll_votes(attrs), do: normalize(adapter().list_poll_votes(attrs))
  def post_status(attrs), do: normalize(adapter().post_status(attrs))
  def status_feed(attrs), do: normalize(adapter().status_feed(attrs))
  def list_status_posts(attrs), do: normalize(adapter().list_status_posts(attrs))
  def delete_status(attrs), do: normalize(adapter().delete_status(attrs))
  def status_media_allowed(attrs), do: normalize(adapter().status_media_allowed(attrs))
  def get_status_audience(attrs), do: normalize(adapter().get_status_audience(attrs))
  def set_status_audience(attrs), do: normalize(adapter().set_status_audience(attrs))
  def record_status_view(attrs), do: normalize(adapter().record_status_view(attrs))
  def status_viewers(attrs), do: normalize(adapter().status_viewers(attrs))
  def my_status(attrs), do: normalize(adapter().my_status(attrs))
  def status_for_reply(attrs), do: normalize(adapter().status_for_reply(attrs))
  def media_download_allowed(attrs), do: normalize(adapter().media_download_allowed(attrs))
  def mark_delivered(attrs), do: normalize(adapter().mark_delivered(attrs))
  def analytics_overview(attrs), do: normalize(adapter().analytics_overview(attrs))
  def analytics_timeseries(attrs), do: normalize(adapter().analytics_timeseries(attrs))
  def admin_delete_message(attrs), do: normalize(adapter().admin_delete_message(attrs))
  def add_reaction(attrs), do: normalize(adapter().add_reaction(attrs))
  def remove_reaction(attrs), do: normalize(adapter().remove_reaction(attrs))
  def star_message(attrs), do: normalize(adapter().star_message(attrs))
  def unstar_message(attrs), do: normalize(adapter().unstar_message(attrs))
  def list_starred(attrs), do: normalize(adapter().list_starred(attrs))
  def search_messages(attrs), do: normalize(adapter().search_messages(attrs))
  def pin_message(attrs), do: normalize(adapter().pin_message(attrs))
  def unpin_message(attrs), do: normalize(adapter().unpin_message(attrs))
  def list_pins(attrs), do: normalize(adapter().list_pins(attrs))
  def list_media(attrs), do: normalize(adapter().list_media(attrs))
  # The conversation a media_id was sent to — read-path authorization for message media.
  def get_by_media_id(attrs), do: normalize(adapter().get_by_media_id(attrs))

  # ERROR NORMALIZATION AT THE BOUNDARY — the completion of a fix that half-landed.
  #
  # `:message_store_unavailable` is the message SERVICE's internal name for "the store could not
  # answer" (a Scylla outage, normalized from Xandra.ConnectionError inside MessageStore, or a
  # deliberate stub). `:message_unavailable` is what every CALLER codes against — ~35 clauses across
  # api_gateway and realtime_gateway, and the atom the HTTP adapter already returns on transport
  # failure. Nothing mapped between them, so every `:message_store_unavailable` crossing this
  # boundary missed all of those clauses and fell through to a catch-all 400 "Request body is
  # invalid".
  #
  # That defeated an EXISTING fix: MessageStore.execute/2 normalizes driver errors to
  # `:message_store_unavailable` with the comment "a store outage must be :message_store_unavailable
  # (503 at the gateway)". The atom was right; the gateway never matched it. Measured before this
  # change — GET messages, GET starred and GET search ALL returned 400 during a simulated store
  # outage, not 503.
  #
  # Normalizing HERE rather than adding a clause to ~35 call sites: this is the seam where the
  # distinction stops being meaningful. Inside message_service the two are worth telling apart (the
  # shadow-read comparator matches on the store one); to a caller they are one fact — the message
  # service could not answer — and one mapping cannot drift out of sync with itself the way 35 can.
  defp normalize({:error, :message_store_unavailable}), do: {:error, :message_unavailable}
  defp normalize(result), do: result

  @doc "The configured Message client adapter (default `MessageService.MessageClientInProcess`)."
  def adapter do
    Application.get_env(
      :shared_infra,
      :message_client_adapter,
      MessageService.MessageClientInProcess
    )
  end
end
