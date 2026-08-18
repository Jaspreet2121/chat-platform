defmodule UserService.QuickRepliesTest do
  @moduledoc """
  Quick replies (100) on real SQL: CRUD scoped to the owner, shortcut format, per-user uniqueness
  (:quick_reply_taken), the 50-cap, explicit reordering, and cross-user invisibility.
  """
  use UserService.DataCase, async: false

  alias UserService.QuickReplies

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  setup do
    prev = Application.get_env(:user_service, :user_profile_persistence, false)
    Application.put_env(:user_service, :user_profile_persistence, true)
    on_exit(fn -> Application.put_env(:user_service, :user_profile_persistence, prev) end)
    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', 'active', now(), now())",
      [id, @tenant_zero, "+1#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp create!(user_id, shortcut, body \\ "the reply body") do
    {:ok, row} =
      QuickReplies.create(%{
        "user_id" => user_id,
        "app_id" => @tenant_zero,
        "shortcut" => shortcut,
        "body" => body
      })

    row
  end

  @tag :postgres_integration
  test "CRUD: create → list (position, shortcut order) → update → delete; other users see nothing" do
    owner = user!()
    other = user!()

    b = create!(owner, "brb")
    a = create!(owner, "address_hint")

    # Same position tier → shortcut order... positions are assigned serially, so insertion order.
    assert {:ok, %{quick_replies: [first, second]}} = QuickReplies.list(%{"user_id" => owner})
    assert first.id == b.id and second.id == a.id

    assert {:ok, updated} =
             QuickReplies.update(%{"user_id" => owner, "id" => a.id, "body" => "new body"})

    assert updated.body == "new body"

    # A stranger can neither read nor touch them.
    assert {:ok, %{quick_replies: []}} = QuickReplies.list(%{"user_id" => other})

    assert {:error, :quick_reply_not_found} =
             QuickReplies.update(%{"user_id" => other, "id" => a.id, "body" => "hijack"})

    assert {:error, :quick_reply_not_found} =
             QuickReplies.delete(%{"user_id" => other, "id" => a.id})

    assert {:ok, %{deleted: true}} = QuickReplies.delete(%{"user_id" => owner, "id" => b.id})
    assert {:ok, %{quick_replies: [%{id: remaining}]}} = QuickReplies.list(%{"user_id" => owner})
    assert remaining == a.id
  end

  @tag :postgres_integration
  test "shortcut format + body bounds + per-user uniqueness" do
    owner = user!()
    peer = user!()

    for bad <- ["Has_Upper", "with space", "/lead", "way_too_long_for_the_limit_x", ""] do
      assert {:error, :invalid_shortcut} =
               QuickReplies.create(%{
                 "user_id" => owner,
                 "app_id" => @tenant_zero,
                 "shortcut" => bad,
                 "body" => "x"
               })
    end

    assert {:error, :invalid_body} =
             QuickReplies.create(%{
               "user_id" => owner,
               "app_id" => @tenant_zero,
               "shortcut" => "ok",
               "body" => String.duplicate("x", 1001)
             })

    create!(owner, "greeting")

    assert {:error, :quick_reply_taken} =
             QuickReplies.create(%{
               "user_id" => owner,
               "app_id" => @tenant_zero,
               "shortcut" => "greeting",
               "body" => "again"
             })

    # ...but uniqueness is PER USER — a peer may use the same shortcut.
    assert %{shortcut: "greeting"} = create!(peer, "greeting")
  end

  @tag :postgres_integration
  test "the 50-cap refuses the 51st" do
    owner = user!()
    for n <- 1..50, do: create!(owner, "s#{n}")

    assert {:error, :quick_reply_limit} =
             QuickReplies.create(%{
               "user_id" => owner,
               "app_id" => @tenant_zero,
               "shortcut" => "one_more",
               "body" => "x"
             })
  end

  @tag :postgres_integration
  test "reorder: position = index; foreign ids in the list are ignored" do
    owner = user!()
    stranger = user!()
    a = create!(owner, "aa")
    b = create!(owner, "bb")
    c = create!(owner, "cc")
    foreign = create!(stranger, "aa")

    assert {:ok, %{quick_replies: rows}} =
             QuickReplies.reorder(%{"user_id" => owner, "ids" => [c.id, a.id, foreign.id, b.id]})

    assert Enum.map(rows, & &1.id) == [c.id, a.id, b.id]

    # The stranger's row was untouched by appearing in someone else's order list.
    assert {:ok, %{quick_replies: [%{id: fid, position: 0}]}} =
             QuickReplies.list(%{"user_id" => stranger})

    assert fid == foreign.id
  end
end
