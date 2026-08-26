defmodule ApiGatewayWeb.UpiQr do
  @moduledoc """
  Async UPI QR (re)generation, orchestrated from the GATEWAY.

  Two reasons it lives here and not in the user service:

    * the media round-trip (render → create-upload → PUT → complete) must stay OFF the PATCH /me
      request path — a slow or down media service must never 503 a profile save (the prod bug this
      fixes: a synchronous server-side PUT to the public MinIO host hung inside the user container
      and blew the gateway's client timeout → `user.unavailable`); and
    * the profile-changed broadcast can only originate here — sockets are mounted in the gateway
      (realtime_gateway); the user-service container can't reach them.

  `update_me` fires `regenerate_async/2` (fire-and-forget) whenever the user service reports
  `upi_qr_pending`. It retries the user-service generator with capped exponential backoff and, on
  success, broadcasts `profile_changed` to the owner's user topic so their clients refetch and the QR
  appears. A permanent failure leaves the profile consistent (fields set, no URL); the next UPI PATCH
  regenerates. Every line carries the stable grep tag `[upi_qr]`.
  """

  require Logger

  @default_max_attempts 5
  @default_base_backoff_ms 500

  @doc "Fire-and-forget async (re)generation for `user_id` in `app_id`. No-op on bad args."
  def regenerate_async(user_id, app_id) when is_binary(user_id) and is_binary(app_id) do
    Task.start(fn -> run(user_id, app_id, 1) end)
    :ok
  end

  def regenerate_async(_user_id, _app_id), do: :ok

  @doc false
  # Exposed for tests: the retry loop, run synchronously.
  def run(user_id, app_id, attempt) do
    case SharedInfra.UserClient.regenerate_upi_qr(%{"user_id" => user_id, "app_id" => app_id}) do
      {:ok, %{upi_qr_media_id: media_id}} when is_binary(media_id) ->
        broadcast_profile_changed(user_id)
        Logger.info("[upi_qr] generated user=#{user_id} media=#{media_id} attempt=#{attempt}")
        :ok

      {:ok, %{upi_qr_media_id: nil}} ->
        # Nothing to generate — the identity was cleared, or a racing clear won. Not a failure.
        Logger.info("[upi_qr] nothing to generate user=#{user_id} (cleared)")
        :ok

      other ->
        if attempt >= max_attempts() do
          Logger.error(
            "[upi_qr] giving up after #{attempt} attempts user=#{user_id}: #{inspect(other)} " <>
              "— profile left consistent (fields set, no URL); next UPI PATCH regenerates"
          )

          :error
        else
          Logger.warning(
            "[upi_qr] attempt #{attempt} failed user=#{user_id}: #{inspect(other)} — retrying"
          )

          Process.sleep(backoff_ms(attempt))
          run(user_id, app_id, attempt + 1)
        end
    end
  end

  defp broadcast_profile_changed(user_id) do
    ApiGatewayWeb.Endpoint.broadcast("user:" <> user_id, "profile_changed", %{
      "type" => "profile_changed"
    })
  rescue
    # A broadcast failure must never crash the background task — the QR is already stored.
    error -> Logger.warning("[upi_qr] broadcast failed user=#{user_id}: #{inspect(error)}")
  end

  # 500ms, 1s, 2s, 4s … — capped by max_attempts. Overridable so tests don't really sleep.
  defp backoff_ms(attempt) do
    (base_backoff_ms() * :math.pow(2, attempt - 1)) |> round()
  end

  defp max_attempts,
    do: Application.get_env(:api_gateway, :upi_qr_max_attempts, @default_max_attempts)

  defp base_backoff_ms,
    do: Application.get_env(:api_gateway, :upi_qr_base_backoff_ms, @default_base_backoff_ms)
end
