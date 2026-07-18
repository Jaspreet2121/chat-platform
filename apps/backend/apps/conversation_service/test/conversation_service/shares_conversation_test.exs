defmodule ConversationService.SharesConversationTest do
  @moduledoc """
  `shares_conversation?/1` — the "contacts" relation behind presence authorization. Both users must be ACTIVE
  participants (left_at NULL) of the SAME conversation. DB-backed (the logic IS a SQL self-join).
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.Conversations

  @app_id "00000000-0000-0000-0000-000000000001"

  setup do
    prev = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)
    on_exit(fn -> Application.put_env(:conversation_service, :conversation_persistence, prev) end)
    :ok
  end

  defp user!, do: with(id <- Ecto.UUID.generate(), do: (Repo.query!("INSERT INTO users_auth (id, app_id, external_id, password_hash, created_at, updated_at) VALUES ($1::text::uuid,$2::text::uuid,$3,'x',now(),now())", [id, @app_id, "ext-#{id}"]); id))

  defp conversation!(creator) do
    id = Ecto.UUID.generate()
    Repo.query!("INSERT INTO conversations (id, type, created_by, status, app_id, created_at, updated_at) VALUES ($1::text::uuid,'group',$2::text::uuid,'active',$3::text::uuid,now(),now())", [id, creator, @app_id])
    id
  end

  defp join!(conv, user, opts \\ []) do
    Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at, left_at) VALUES ($1::text::uuid,$2::text::uuid,'member',now(),$3)",
      [conv, user, Keyword.get(opts, :left_at)]
    )
  end

  defp shares?(a, b) do
    {:ok, %{shares: shares}} = Conversations.shares_conversation?(%{"user_a" => a, "user_b" => b})
    shares
  end

  test "two active participants of the same conversation SHARE" do
    a = user!()
    b = user!()
    conv = conversation!(a)
    join!(conv, a)
    join!(conv, b)
    assert shares?(a, b)
    # symmetric
    assert shares?(b, a)
  end

  test "no common conversation → do NOT share" do
    a = user!()
    b = user!()
    c1 = conversation!(a)
    c2 = conversation!(b)
    join!(c1, a)
    join!(c2, b)
    refute shares?(a, b)
  end

  test "a participant who LEFT (left_at set) no longer shares" do
    a = user!()
    b = user!()
    conv = conversation!(a)
    join!(conv, a)
    join!(conv, b, left_at: DateTime.utc_now())
    refute shares?(a, b)
  end

  test "self is not treated as a shared edge (returns false)" do
    a = user!()
    conv = conversation!(a)
    join!(conv, a)
    refute shares?(a, a)
  end

  test "invalid uuids are rejected, not crashed" do
    assert {:error, :conversation_invalid} =
             Conversations.shares_conversation?(%{"user_a" => "nope", "user_b" => Ecto.UUID.generate()})
  end
end
