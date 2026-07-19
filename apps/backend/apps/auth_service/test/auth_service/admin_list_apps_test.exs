defmodule AuthService.AdminListAppsTest do
  @moduledoc """
  `Apps.admin_list_apps/1` — the cross-tenant operator view. What matters: counts are per-tenant and correct
  (the MESSAGE count via the parent-conversation join — the same trap the owner usage slice hit), the test
  twin folds into its live parent (keys) while staying a badge (not a row), owner identity resolves, and NO
  secret material appears anywhere in the response.
  """
  use AuthService.DataCase, async: false

  @moduletag :postgres_integration

  alias AuthService.Apps

  defp app!(name, opts \\ []) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO apps (id, name, slug, mode, parent_app_id, created_at, updated_at) VALUES ($1::text::uuid, $2, $3, $4, $5::text::uuid, now(), now())",
      [id, name, "slug-#{id}", Keyword.get(opts, :mode, "live"), Keyword.get(opts, :parent)]
    )

    id
  end

  defp user!(app_id, opts \\ []) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, external_id, password_hash, created_at, updated_at) VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', now(), now())",
      [id, app_id, "ext-#{id}"]
    )

    if name = Keyword.get(opts, :display_name) do
      Repo.query!(
        "INSERT INTO user_profiles (user_id, display_name, created_at, updated_at) VALUES ($1::text::uuid, $2, now(), now())",
        [id, name]
      )
    end

    id
  end

  defp own!(app_id, user_id),
    do: Repo.query!("INSERT INTO app_owners (app_id, owner_user_id) VALUES ($1::text::uuid, $2::text::uuid)", [app_id, user_id])

  defp conversation!(app_id, creator) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by, status, app_id, created_at, updated_at) VALUES ($1::text::uuid, 'group', $2::text::uuid, 'active', $3::text::uuid, now(), now())",
      [id, creator, app_id]
    )

    id
  end

  # THE TRAP: messages carry their own app_id column, but tenancy is authoritative via the PARENT
  # CONVERSATION. Write a mismatched app_id on purpose — the count must follow the conversation.
  defp message!(conversation_id, sender, wrong_app_id) do
    Repo.query!(
      "INSERT INTO messages (message_id, conversation_id, sender_user_id, message_type, body, status, created_at, app_id) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, 'text', 'hi', 'active', now(), $4::text::uuid)",
      [Ecto.UUID.generate(), conversation_id, sender, wrong_app_id]
    )
  end

  defp key!(app_id, mode, opts \\ []) do
    Repo.query!(
      "INSERT INTO api_keys (id, app_id, name, key_hash, key_prefix, mode, created_at, revoked_at) VALUES ($1::text::uuid, $2::text::uuid, 'k', $3, $4, $5, now(), $6)",
      [Ecto.UUID.generate(), app_id, "hash-#{Ecto.UUID.generate()}", "sk_#{mode}_abc", mode, Keyword.get(opts, :revoked_at)]
    )
  end

  defp endpoint!(app_id, enabled) do
    Repo.query!(
      "INSERT INTO webhook_endpoints (id, app_id, url, signing_secret, event_types, enabled, created_at, updated_at) VALUES ($1::text::uuid, $2::text::uuid, 'https://x.test', 'whsec_secret', '{}', $3, now(), now())",
      [Ecto.UUID.generate(), app_id, enabled]
    )
  end

  defp find_app(apps, id), do: Enum.find(apps, &(&1.app_id == id))

  test "two tenants: correct per-app counts, message count via the PARENT-CONVERSATION join" do
    owner_a = nil

    app_a = app!("Acme")
    app_b = app!("Beta")
    ua = user!(app_a, display_name: "Alice Owner")
    ub1 = user!(app_b)
    _ub2 = user!(app_b)
    own!(app_a, ua)
    own!(app_b, ub1)

    conv_a = conversation!(app_a, ua)
    # Two messages in A's conversation — both stamped with B's app_id on the row (the trap). The count must
    # still attribute them to A via the conversation.
    message!(conv_a, ua, app_b)
    message!(conv_a, ua, app_b)

    {:ok, %{apps: apps}} = Apps.admin_list_apps(%{})

    a = find_app(apps, app_a)
    b = find_app(apps, app_b)

    assert a.counts == %{users: 1, conversations: 1, messages: 2, storage_bytes: 0}
    assert a.owner == %{user_id: ua, display: "Alice Owner"}
    refute a.test_twin

    # B: two users, no conversations — and crucially ZERO messages despite the rows stamped with its app_id.
    assert b.counts == %{users: 2, conversations: 0, messages: 0, storage_bytes: 0}
    assert b.owner.user_id == ub1
    _ = owner_a
  end

  test "the test twin FOLDS into its live parent (keys) and shows as a badge, not a row" do
    app = app!("WithTwin")
    twin = app!("WithTwin (test)", mode: "test", parent: app)
    own!(app, user!(app))

    # Live key under the live app; test keys live under the TWIN app_id (the 054 design); one revoked.
    key!(app, "live")
    key!(twin, "test")
    key!(twin, "test")
    key!(app, "live", revoked_at: DateTime.utc_now())

    endpoint!(app, true)
    endpoint!(twin, false)

    {:ok, %{apps: apps}} = Apps.admin_list_apps(%{})

    row = find_app(apps, app)
    assert row.test_twin
    assert row.api_keys == %{live: 1, test: 2, revoked: 1}
    assert row.webhooks == %{total: 2, enabled: 1}

    # The twin is NOT its own row.
    refute find_app(apps, twin)
  end

  test "?q= filters by name (and id)" do
    app = app!("Searchable Unicorn")
    _other = app!("Plain")
    own!(app, user!(app))

    {:ok, %{apps: apps}} = Apps.admin_list_apps(%{"q" => "unicorn"})
    assert Enum.map(apps, & &1.app_id) == [app]

    {:ok, %{apps: by_id}} = Apps.admin_list_apps(%{"q" => String.slice(app, 0, 8)})
    assert app in Enum.map(by_id, & &1.app_id)
  end

  test "NO secret material anywhere in the response (keys are counts; endpoints are counts)" do
    app = app!("Sec")
    own!(app, user!(app))
    key!(app, "live")
    endpoint!(app, true)

    {:ok, %{apps: apps}} = Apps.admin_list_apps(%{})
    row = find_app(apps, app)

    # The row's entire key set is fixed metadata — nothing shaped like a hash, prefix, or secret.
    assert Map.keys(row) |> Enum.sort() ==
             [:api_keys, :app_id, :counts, :created_at, :name, :owner, :test_twin, :webhooks]

    flat = inspect(row)
    refute flat =~ "sk_live"
    refute flat =~ "hash-"
    refute flat =~ "whsec"
    refute flat =~ "signing_secret"
  end

  test "an ownerless app (tenant zero style) renders with owner nil, not a crash" do
    app = app!("NoOwner")
    {:ok, %{apps: apps}} = Apps.admin_list_apps(%{})
    assert find_app(apps, app).owner == nil
  end
end
