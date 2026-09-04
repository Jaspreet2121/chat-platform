defmodule ApiGatewayWeb.MediaUploadRateLimitTest do
  @moduledoc """
  UPLOAD CREATION LIMITS — 60/minute and 500/day per user.

  Each create issues a presigned PUT and the bytes never pass through this app, so what is being
  limited is how many presigned URLs a user can obtain. That was unbounded: one session in a loop
  filled MinIO, and a full disk takes the platform down for everyone, not just the abuser.

  Proves: both windows fire with 429 + Retry-After; a legitimate burst below the per-minute limit does
  not; the DAILY window is the one charged first (its Retry-After is what a client sees, and it is the
  limit that bounds accumulation); the key is per-user; and it FAILS CLOSED.

  FAIL-CLOSED IS A REVERSAL, recorded here so the next reader does not "restore" it. This limiter used
  to fail OPEN on the reasoning that losing a user's photo to a Redis blip costs more than briefly
  skipping an abuse guard. What that traded away is worse: the moment the limiter breaks is exactly the
  moment the cap stops existing, silently and with no upper bound, and nothing in the system says so.
  An upload is retryable and non-destructive, so refusing during an outage costs a retry; admitting
  uncapped costs unbounded storage. The degraded branch now logs at ERROR so an outage is visible
  rather than inferred from a bill.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.MediaController
  alias SharedInfra.RateLimiter

  # Must match the module attributes in MediaController.
  @burst 60
  @burst_window 60
  @daily 500
  @daily_window 86_400

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer " <> user}),
      do: {:ok, %{user_id: user, app_id: "app-1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule MediaStub do
    @moduledoc false
    def create_upload(_attrs),
      do: {:ok, %{media_id: "m-1", object_key: "k", upload_url: "https://s/put"}}
  end

  setup do
    keys = [:auth_client_adapter, :media_client_adapter, :rate_limiter_adapter]
    prev = for k <- keys, into: %{}, do: {k, Application.get_env(:shared_infra, k)}
    prev_persist = Application.get_env(:media_service, :media_persistence)

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateLimiter.InMemoryAdapter)
    Application.put_env(:media_service, :media_persistence, true)

    start_in_memory_adapter!()
    RateLimiter.InMemoryAdapter.reset()

    on_exit(fn ->
      RateLimiter.InMemoryAdapter.reset()

      for {k, v} <- prev do
        if v,
          do: Application.put_env(:shared_infra, k, v),
          else: Application.delete_env(:shared_infra, k)
      end

      if prev_persist,
        do: Application.put_env(:media_service, :media_persistence, prev_persist),
        else: Application.delete_env(:media_service, :media_persistence)
    end)

    :ok
  end

  test "a legitimate burst below the per-minute limit is never throttled" do
    # Two full multi-image batches back to back (30 images each is the common cap for that UI).
    for n <- 1..@burst do
      refute upload("u-burst").status == 429, "upload #{n} should not be rate limited"
    end
  end

  test "over the per-minute limit → 429 with the burst Retry-After" do
    for _ <- 1..@burst, do: upload("u-fast")

    conn = upload("u-fast")

    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") == [Integer.to_string(@burst_window)]
    assert %{"error" => %{"code" => "media.rate_limited"}} = Jason.decode!(conn.resp_body)
  end

  test "the DAILY cap is checked FIRST — when BOTH would trip, the long Retry-After wins" do
    # Exhaust the DAY key directly in the limiter (no clock games), THEN exhaust the minute window
    # through the controller. Both are now over, which is the only situation in which the ORDER of
    # the two checks is observable — an earlier version of this test left the minute window untouched
    # and passed under either order, so it proved nothing.
    for _ <- 1..@daily do
      RateLimiter.check_rate(%{
        "key" => "media_upload_day:u-day",
        "limit" => @daily,
        "window_seconds" => @daily_window
      })
    end

    for _ <- 1..@burst, do: upload("u-day")

    conn = upload("u-day")

    assert conn.status == 429

    # The DAY window's Retry-After, not the minute's. The daily limit is charged first precisely so
    # the client is told the REAL wait when both would trip — being told to retry in 60s when the
    # daily budget is gone is a lie that produces a retry loop.
    [retry] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry) > @burst_window
    assert String.to_integer(retry) <= @daily_window
  end

  test "SCOPING: one user's uploads never consume another's budget" do
    for _ <- 1..(@burst + 1), do: upload("u-noisy")
    assert upload("u-noisy").status == 429

    # Without per-user keying one abuser would block everyone from sending media — a denial of
    # service built out of the anti-abuse control.
    refute upload("u-quiet").status == 429
  end

  test "FAIL-CLOSED: a limiter outage refuses the upload rather than silently uncapping it" do
    # Deliberate. Failing closed would be worth the breakage only if this were tight disk protection,
    # and it is not: at the 100 MB per-object cap a full daily budget is still ~50 GB per account.
    # It turns unbounded into bounded; the disk is properly defended by a byte quota and alerting.
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateLimiter.RedisQueryPlanAdapter)

    conn = upload("u-outage")

    # 429, not 503: the client's correct response is to back off and retry, which is what a rate-limit
    # status tells it to do. Retry-After is present so it knows how long.
    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") != []
  end

  defp upload(user) do
    :post
    |> conn("/x", %{})
    |> put_req_header("authorization", "Bearer " <> user)
    |> MediaController.create_upload(upload_params())
  end

  defp upload_params do
    %{
      "filename" => "photo.png",
      "content_type" => "image/png",
      "size_bytes" => 1024,
      "purpose" => "message"
    }
  end

  defp start_in_memory_adapter! do
    case RateLimiter.InMemoryAdapter.start_link() do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok
    end
  end
end
