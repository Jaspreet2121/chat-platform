defmodule ApiGatewayWeb.ContactSyncTest do
  @moduledoc """
  Contacts sync — POST /api/v1/contacts/sync. Docker-free: Auth/User/Conversation/Media clients + the
  rate limiter are stubbed, no DB/HTTP. Proves the privacy-critical contract:

    * a mixed batch returns ONLY the matches, self excluded, non-matches absent, the input phone echoed;
    * a blocked contact and a photo-hidden contact are redacted EXACTLY as the REAL single by-phone
      lookup redacts them — asserted by comparing each match to the ACTUAL by_phone response for the same
      user (so the two paths can't drift: they run the same ProfilePresenter);
    * an over-size batch → 400 contacts.batch_too_large carrying {max}; the rate limit → 429 + Retry-After;
      a limiter OUTAGE → 503 + Retry-After (fail CLOSED — the limit is a security control here);
    * malformed (non-E.164) entries are SKIPPED, never rejecting the batch;
    * the phone→user match is ONE bulk lookup regardless of batch size (500 entries → 1 call).

  The app-scoped SQL itself is proven in AuthService.AccountsPhoneLookupTest (@tag :postgres_integration).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.{ContactController, UserController}

  @me "u-me"
  @visible "u-visible"
  @blocked "u-blocked"
  @hidden "u-hidden"

  @p_visible "+15550000001"
  @p_blocked "+15550000002"
  @p_hidden "+15550000003"
  @p_self "+15550000009"
  @p_nomatch "+15550000000"

  defmodule AuthStub do
    @moduledoc false
    @app "app-1"

    # Counts lookup_users_by_phones invocations — the "one query regardless of batch size" assertion.
    def start_link, do: Agent.start_link(fn -> 0 end, name: __MODULE__)
    def bulk_calls, do: Agent.get(__MODULE__, & &1)

    def current_session(%{"authorization" => "Bearer me"}), do: {:ok, %{user_id: "u-me", app_id: @app}}
    def current_session(_), do: {:error, :session_invalid}

    # Single lookup (the by-phone comparison path) — app_id is now passed but the stub matches on phone.
    def lookup_user_by_phone(%{"phone_number" => phone}) do
      case phone_to_user(phone) do
        nil -> {:error, :not_found}
        uid -> {:ok, %{user_id: uid}}
      end
    end

    # Bulk lookup — ONE call returns rows for the known phones (echoing the input), counts the invocation.
    def lookup_users_by_phones(%{"phone_numbers" => phones, "app_id" => @app}) do
      Agent.update(__MODULE__, &(&1 + 1))

      rows =
        Enum.flat_map(phones, fn p ->
          case phone_to_user(p) do
            nil -> []
            uid -> [%{user_id: uid, phone_number: p}]
          end
        end)

      {:ok, rows}
    end

    defp phone_to_user("+15550000001"), do: "u-visible"
    defp phone_to_user("+15550000002"), do: "u-blocked"
    defp phone_to_user("+15550000003"), do: "u-hidden"
    defp phone_to_user("+15550000009"), do: "u-me"
    defp phone_to_user(_), do: nil
  end

  defmodule UserStub do
    @moduledoc false
    @app "app-1"

    # App-scoped profile: only resolves in the caller's app (cross-tenant → absent). Every match has an
    # avatar so a redaction (blocked/hidden) is VISIBLE as avatar_url going nil.
    def get_public_profile(%{"user_id" => uid, "app_id" => @app}), do: profile(uid)
    def get_public_profile(_), do: {:error, :profile_not_found}

    def get_privacy(%{"user_id" => uid}), do: {:ok, %{profile_photo_visibility: visibility(uid)}}

    defp profile("u-visible"),
      do: {:ok, %{user_id: "u-visible", display_name: "Visible", avatar_media_id: "m-vis", app_id: @app, bio: nil}}

    defp profile("u-blocked"),
      do: {:ok, %{user_id: "u-blocked", display_name: "Blocked", avatar_media_id: "m-blk", app_id: @app, bio: nil}}

    defp profile("u-hidden"),
      do: {:ok, %{user_id: "u-hidden", display_name: "Hidden", avatar_media_id: "m-hid", app_id: @app, bio: nil}}

    defp profile("u-me"),
      do: {:ok, %{user_id: "u-me", display_name: "Me", avatar_media_id: nil, app_id: @app, bio: nil}}

    defp profile(_), do: {:error, :profile_not_found}

    # everyone → shown; nobody → hidden. (u-blocked is "everyone" so ONLY the block hides its avatar.)
    defp visibility("u-hidden"), do: "nobody"
    defp visibility(_), do: "everyone"
  end

  defmodule ConvStub do
    @moduledoc false
    # A block (either direction) with u-blocked; nothing else blocked. shares_conversation? is irrelevant
    # here (visibility uses everyone/nobody), but present may call it → answer false.
    def either_blocked?(%{"user_a" => a, "user_b" => b}) do
      if "u-blocked" in [a, b], do: {:ok, %{blocked: true}}, else: {:ok, %{blocked: false}}
    end

    def shares_conversation?(_), do: {:ok, %{shares: false}}
  end

  defmodule MediaStub do
    @moduledoc false
    @app "app-1"
    # Presign any avatar media in the caller's app → a deterministic URL, so a shown avatar has a value.
    def get_download_url(%{"media_id" => mid, "app_id" => @app, "purpose" => "user_avatar"}),
      do: {:ok, %{download_url: "https://signed/" <> mid}}

    def get_download_url(_), do: {:error, :not_found}
  end

  defmodule RateOkStub do
    @moduledoc false
    def check_rate(_), do: :ok
  end

  defmodule RateLimitedStub do
    @moduledoc false
    def check_rate(_), do: {:error, :rate_limited, 42}
  end

  defmodule RateOutageStub do
    @moduledoc false
    def check_rate(_), do: {:error, :rate_limiter_unavailable, :boom}
  end

  setup do
    start_supervised!(%{id: AuthStub, start: {AuthStub, :start_link, []}})

    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      user: Application.get_env(:shared_infra, :user_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter),
      media: Application.get_env(:shared_infra, :media_client_adapter),
      rate: Application.get_env(:shared_infra, :rate_limiter_adapter)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateOkStub)

    on_exit(fn ->
      restore(:auth_client_adapter, prev.auth)
      restore(:user_client_adapter, prev.user)
      restore(:conversation_client_adapter, prev.conv)
      restore(:media_client_adapter, prev.media)
      restore(:rate_limiter_adapter, prev.rate)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp authed(token \\ "me") do
    :post |> conn("/x", %{}) |> put_req_header("authorization", "Bearer #{token}")
  end

  defp sync(phone_numbers, token \\ "me") do
    ContactController.sync(authed(token), %{"phone_numbers" => phone_numbers})
  end

  defp matches(conn), do: Jason.decode!(conn.resp_body)["matches"]
  defp match_for(conn, phone), do: Enum.find(matches(conn), &(&1["phone"] == phone))

  # The REAL single by-phone response for a phone (what the client would get for one lookup).
  defp by_phone(phone) do
    UserController.by_phone(authed(), %{"phone" => phone}) |> then(&Jason.decode!(&1.resp_body))
  end

  test "a mixed batch returns ONLY matches, self excluded, non-matches absent, input phone echoed" do
    conn = sync([@p_visible, @p_blocked, @p_hidden, @p_self, @p_nomatch])
    assert conn.status == 200

    ms = matches(conn)
    # Three matches; self (u-me) and the unknown number are NOT present.
    assert length(ms) == 3
    assert Enum.map(ms, & &1["user_id"]) |> Enum.sort() == Enum.sort([@visible, @blocked, @hidden])
    refute Enum.any?(ms, &(&1["user_id"] == @me))
    refute Enum.any?(ms, &(&1["phone"] == @p_nomatch))

    # The input phone is echoed on each match (the join key back to the address book).
    assert match_for(conn, @p_visible)["user_id"] == @visible
    assert match_for(conn, @p_blocked)["user_id"] == @blocked
    assert match_for(conn, @p_hidden)["user_id"] == @hidden
  end

  test "blocked + photo-hidden contacts are redacted EXACTLY as the REAL single by-phone lookup" do
    # For each target, the bulk match item must equal the actual by_phone response (same ProfilePresenter).
    for phone <- [@p_visible, @p_blocked, @p_hidden] do
      single = by_phone(phone)
      item = match_for(sync([phone]), phone)

      assert item["user_id"] == single["user_id"]
      assert item["display_name"] == single["display_name"]
      assert item["avatar_url"] == single["avatar_url"]
    end

    # …and confirm the redaction actually fired: visible shows a URL, blocked + hidden are nil (both ways).
    assert match_for(sync([@p_visible]), @p_visible)["avatar_url"] == "https://signed/m-vis"
    assert match_for(sync([@p_blocked]), @p_blocked)["avatar_url"] == nil
    assert match_for(sync([@p_hidden]), @p_hidden)["avatar_url"] == nil
    # by_phone agrees (proves the comparison above wasn't nil == nil by accident on the visible case).
    assert by_phone(@p_visible)["avatar_url"] == "https://signed/m-vis"
  end

  test "an over-size batch → 400 contacts.batch_too_large carrying {max: 2000}" do
    over = for i <- 1..2001, do: "+1555" <> String.pad_leading(Integer.to_string(i), 7, "0")
    conn = sync(over)

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "contacts.batch_too_large"
    assert body["error"]["max"] == 2000
  end

  test "the rate limit fires → 429 contacts.rate_limited + Retry-After" do
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateLimitedStub)

    conn = sync([@p_visible])
    assert conn.status == 429
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "contacts.rate_limited"
    assert get_resp_header(conn, "retry-after") == ["42"]
  end

  test "a limiter OUTAGE → 503 contacts.unavailable + a short Retry-After (fail CLOSED)" do
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateOutageStub)

    conn = sync([@p_visible])
    assert conn.status == 503
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "contacts.unavailable"
    assert get_resp_header(conn, "retry-after") == ["30"]
  end

  test "malformed (non-E.164) entries are SKIPPED, not rejected — valid ones still match" do
    conn = sync([@p_visible, "not-a-number", "", "+abc", "12345", "  "])
    assert conn.status == 200

    ms = matches(conn)
    assert length(ms) == 1
    assert hd(ms)["user_id"] == @visible
  end

  test "an all-malformed batch → 200 with no matches and NO lookup query" do
    conn = sync(["nope", "", "12345"])
    assert conn.status == 200
    assert matches(conn) == []
    assert AuthStub.bulk_calls() == 0
  end

  test "ONE lookup query regardless of batch size (500 entries → a single bulk call)" do
    batch = for i <- 1..500, do: "+1555" <> String.pad_leading(Integer.to_string(i), 7, "0")
    conn = sync(batch)

    assert conn.status == 200
    # The known matches (indices 1/2/3 → visible/blocked/hidden; 9 → self, excluded) still resolve…
    assert length(matches(conn)) == 3
    # …and the phone→user resolution was a SINGLE bulk lookup, not 500.
    assert AuthStub.bulk_calls() == 1
  end

  test "no session → 401" do
    conn = sync([@p_visible], "nobody")
    assert conn.status == 401
  end

  test "a non-list body → 400 contacts.phone_numbers_required" do
    conn = ContactController.sync(authed(), %{"phone_numbers" => "not-a-list"})
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "contacts.phone_numbers_required"
  end
end
