defmodule UserService.UserSearchTest do
  @moduledoc """
  The display-name/username substring search (098) on real SQL: substring + prefix-first ordering,
  case-insensitivity, LIKE-wildcard escaping (a q containing % or _ matches those LITERALS), the
  caller excluded, app isolation (a foreign tenant's matching row is invisible — mutation-proven),
  ACTIVE-only status parity with by-phone/by-username, and the limit.
  """
  use UserService.DataCase, async: false

  alias UserService.Profiles

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  setup do
    prev = Application.get_env(:user_service, :user_profile_persistence, false)
    Application.put_env(:user_service, :user_profile_persistence, true)
    on_exit(fn -> Application.put_env(:user_service, :user_profile_persistence, prev) end)
    :ok
  end

  defp user!(display_name, opts \\ []) do
    app_id = Keyword.get(opts, :app_id, @tenant_zero)
    status = Keyword.get(opts, :status, "active")
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', $4, now(), now())",
      [id, app_id, "+1#{System.unique_integer([:positive])}", status]
    )

    Repo.query!(
      "INSERT INTO user_profiles (user_id, display_name, app_id, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, $3::text::uuid, now(), now())",
      [id, display_name, app_id]
    )

    case Keyword.get(opts, :username) do
      nil ->
        :ok

      username ->
        Repo.query!(
          "UPDATE user_profiles SET username = $2, username_key = lower($2) " <>
            "WHERE user_id = $1::text::uuid",
          [id, username]
        )
    end

    id
  end

  defp app! do
    id = Ecto.UUID.generate()

    Repo.query!("INSERT INTO apps (id, name, slug) VALUES ($1::text::uuid, 'T', $2)", [
      id,
      "t-#{id}"
    ])

    id
  end

  defp search!(q, caller, opts \\ []) do
    {:ok, %{users: users}} =
      Profiles.search_users(%{
        "q" => q,
        "app_id" => Keyword.get(opts, :app_id, @tenant_zero),
        "caller_user_id" => caller,
        "limit" => Keyword.get(opts, :limit)
      })

    users
  end

  @tag :postgres_integration
  test "substring matches BOTH columns, case-insensitively; prefix matches order first" do
    caller = user!("The Caller")
    deep = user!("Deep Singh")
    zorro = user!("Zorro", username: "DeepakZ")
    amandeep = user!("Amandeep Kaur")

    ids = search!("dEEp", caller) |> Enum.map(& &1.user_id)

    # All three match (display prefix / username prefix / display substring)…
    assert Enum.sort(ids) == Enum.sort([deep, zorro, amandeep])

    # …and the two PREFIX matches lead, ordered by display_name; the substring-only match trails.
    assert ids == [deep, zorro, amandeep]
  end

  @tag :postgres_integration
  test "% and _ in q are LITERALS, never wildcards" do
    caller = user!("The Caller")
    literal = user!("100% Legit")
    _decoy = user!("100X Legit")

    assert search!("00% l", caller) |> Enum.map(& &1.user_id) == [literal]

    underscore = user!("a_b Corp")
    _decoy2 = user!("aXb Corp")
    assert search!("a_b", caller) |> Enum.map(& &1.user_id) == [underscore]
  end

  @tag :postgres_integration
  test "the caller never appears in their own results" do
    caller = user!("Findable Caller")
    other = user!("Findable Other")

    ids = search!("findable", caller) |> Enum.map(& &1.user_id)
    assert other in ids
    refute caller in ids
  end

  @tag :postgres_integration
  test "APP ISOLATION: a foreign tenant's matching row is invisible; inactive accounts too" do
    caller = user!("The Caller")
    mine = user!("Isolde Example")
    foreign_app = app!()
    foreign = user!("Isolde Example", app_id: foreign_app)
    suspended = user!("Isolde Suspended", status: "suspended")

    ids = search!("isolde", caller) |> Enum.map(& &1.user_id)
    assert ids == [mine]
    refute foreign in ids
    refute suspended in ids
  end

  @tag :postgres_integration
  test "limit caps the page (and the card carries the presenter's inputs, incl. app_id)" do
    caller = user!("The Caller")
    for n <- 1..3, do: user!("Pageuser #{n}")

    rows = search!("pageuser", caller, limit: 2)
    assert length(rows) == 2

    [row | _] = rows
    assert row.app_id == @tenant_zero
    assert is_binary(row.display_name)
    assert Map.has_key?(row, :username)
    assert Map.has_key?(row, :avatar_media_id)

    # 100: SEARCH CARDS NEVER CARRY PAYMENT (or business) FIELDS — a directory listing must not
    # become a payment-detail sweep. Locked against the SELECT itself (mutation-proven).
    for key <- [:upi_id, :payment_name, :upi_qr_media_id, :upi_merchant, :profile_visibility] do
      refute Map.has_key?(row, key)
    end
  end

  @tag :postgres_integration
  test "DATING LEAK LOCK (105): the search card's key set is exact — dating data never rides it" do
    caller = user!("Caller")
    target = user!("Dating Person")

    # The target HAS a dating profile — the search card must still carry only its own fields.
    Repo.query!(
      "INSERT INTO dating_profiles (user_id, app_id, enabled, dob, gender, bio, intention, turn_ons) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, true, '1999-01-01', 'woman', 'DATING-ONLY BIO', " <>
        "'serious', '{kissing,chai_dates}')",
      [target, @tenant_zero]
    )

    assert [card] = search!("Dating Person", caller)

    assert Map.keys(card) |> Enum.sort() ==
             [
               :app_id,
               :avatar_media_id,
               :avatar_object_key,
               :bio,
               :display_name,
               :user_id,
               :username
             ]

    refute card.bio == "DATING-ONLY BIO"
  end

  test "persistence off → empty result, never an error (unit-tier default)" do
    Application.put_env(:user_service, :user_profile_persistence, false)

    assert {:ok, %{users: []}} =
             Profiles.search_users(%{
               "q" => "abc",
               "app_id" => @tenant_zero,
               "caller_user_id" => Ecto.UUID.generate()
             })
  end
end
