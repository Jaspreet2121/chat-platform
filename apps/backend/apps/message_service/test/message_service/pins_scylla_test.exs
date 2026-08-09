defmodule MessageService.PinsScyllaTest do
  @moduledoc """
  PINS FOR SCYLLA-ONLY MESSAGES — the live defect from the [2026-08-09] sweep: pinning any
  post-cutover message failed `:message_not_found` (validation against the frozen Postgres table)
  and the 092 FK made success structurally impossible. These tests run against a store stub holding
  messages that DO NOT exist in Postgres `messages` — the exact post-cutover shape.

  `PinsTest` (the Postgres-seeded suite) proves the mask semantics carried over unchanged; this
  file proves the store path, the FK's absence, the deletion story, and the outage behaviour.
  """
  use MessageService.DataCase, async: false

  alias MessageService.Pins
  alias MessageService.Projections.InboxFromTopic

  @tenant "00000000-0000-0000-0000-000000000001"

  defmodule StoreStub do
    @moduledoc false
    use Agent

    def start do
      case Agent.start_link(fn -> %{} end, name: __MODULE__) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)

    def put(message),
      do:
        Agent.update(
          __MODULE__,
          &Map.put(&1, {message.conversation_id, message.message_id}, message)
        )

    def tombstone(conversation_id, message_id) do
      Agent.update(__MODULE__, fn state ->
        case Map.get(state, {conversation_id, message_id}) do
          nil ->
            state

          m ->
            Map.put(state, {conversation_id, message_id}, %{m | deleted_at: DateTime.utc_now()})
        end
      end)
    end

    def get_message(attrs) do
      key = {attrs["conversation_id"], attrs["message_id"]}

      case Agent.get(__MODULE__, &Map.get(&1, key)) do
        nil -> {:error, :message_not_found}
        message -> {:ok, message}
      end
    end

    def list_messages(attrs) do
      conversation_id = attrs["conversation_id"]

      messages =
        Agent.get(__MODULE__, &Map.values(&1))
        |> Enum.filter(&(&1.conversation_id == conversation_id))
        |> Enum.sort_by(& &1.created_at, {:desc, DateTime})

      {:ok, %{messages: messages, next_cursor: nil}}
    end
  end

  defmodule DownStore do
    @moduledoc false
    def get_message(_attrs), do: {:error, :message_store_unavailable}
  end

  setup do
    prev = Application.get_env(:message_service, :message_store_adapter)
    Application.put_env(:message_service, :message_store_adapter, StoreStub)
    StoreStub.start()
    StoreStub.reset()

    on_exit(fn ->
      if prev,
        do: Application.put_env(:message_service, :message_store_adapter, prev),
        else: Application.delete_env(:message_service, :message_store_adapter)
    end)

    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp conversation!(members) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid)",
      [id, @tenant, hd(members)]
    )

    for u <- members do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [id, u]
      )
    end

    id
  end

  # A message that exists ONLY in the store — nothing in Postgres `messages`. The defect's shape.
  defp scylla_only_message(conversation, sender, opts \\ []) do
    m = %{
      conversation_id: conversation,
      message_id: Ecto.UUID.generate(),
      sender_user_id: sender,
      message_type: "text",
      body: "scylla only",
      status: "active",
      metadata: %{},
      created_at: Keyword.get(opts, :created_at, DateTime.utc_now()),
      deleted_at: nil
    }

    StoreStub.put(m)
    m
  end

  defp pin!(conversation, message_id, user) do
    Pins.pin_message(%{
      "conversation_id" => conversation,
      "message_id" => message_id,
      "user_id" => user
    })
  end

  defp list!(conversation, viewer) do
    {:ok, %{pins: pins}} =
      Pins.list_pins(%{"conversation_id" => conversation, "user_id" => viewer})

    pins
  end

  defp pin_rows(conversation) do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM message_pins WHERE conversation_id = $1::text::uuid",
        [conversation]
      )

    n
  end

  @tag :postgres_integration
  test "(a) THE DEFECT: pinning a Scylla-only message succeeds" do
    [sender, viewer] = users = [user!(), user!()]
    conversation = conversation!(users)
    m = scylla_only_message(conversation, sender)

    assert {:ok, %{pinned: true}} = pin!(conversation, m.message_id, sender)
    assert [%{message_id: id}] = list!(conversation, viewer)
    assert id == m.message_id
  end

  @tag :postgres_integration
  test "(b) the payload keeps the CONTRACT shape — ids only, exactly three keys" do
    [sender, viewer] = users = [user!(), user!()]
    conversation = conversation!(users)
    m = scylla_only_message(conversation, sender)
    assert {:ok, _} = pin!(conversation, m.message_id, sender)

    assert [pin] = list!(conversation, viewer)
    # The contract (conversation-service.md): ids only, the client holds bodies from the
    # transcript. The Android DTO parses exactly this — no regression, no additions.
    assert Map.keys(pin) |> Enum.sort() == [:message_id, :pinned_at, :pinned_by]
    assert pin.pinned_by == sender
  end

  @tag :postgres_integration
  test "(c) pinned-then-deleted: the consumer's delete handler REMOVES the row (cap freed), and " <>
         "hydration hides a missed unpin" do
    [sender, viewer] = users = [user!(), user!()]
    conversation = conversation!(users)
    m = scylla_only_message(conversation, sender)
    assert {:ok, _} = pin!(conversation, m.message_id, sender)
    assert pin_rows(conversation) == 1

    StoreStub.tombstone(conversation, m.message_id)

    # The at-least-once path: the delete EVENT removes the pin row — the CASCADE's replacement,
    # keeping the max_pins cap honest even when the synchronous unpin was missed.
    assert {:ok, :applied} =
             InboxFromTopic.apply_message_deleted(%{
               "event_id" => Ecto.UUID.generate(),
               "event_type" => "message.deleted.v1",
               "payload" => %{
                 "conversation_id" => conversation,
                 "message_id" => m.message_id,
                 "sender_user_id" => sender,
                 "deleted_at" => DateTime.utc_now()
               }
             })

    assert pin_rows(conversation) == 0
    assert list!(conversation, viewer) == []

    # The net underneath: a tombstoned pin whose EVERY unpin write was missed still never renders.
    m2 = scylla_only_message(conversation, sender)
    assert {:ok, _} = pin!(conversation, m2.message_id, sender)
    StoreStub.tombstone(conversation, m2.message_id)
    assert pin_rows(conversation) == 1
    assert list!(conversation, viewer) == []
  end

  @tag :postgres_integration
  test "(d) the per-viewer mask holds against store-hydrated values" do
    [sender, cleared, fresh] = users = [user!(), user!(), user!()]
    conversation = conversation!(users)
    m = scylla_only_message(conversation, sender)
    assert {:ok, _} = pin!(conversation, m.message_id, sender)

    # One viewer cleared their history AFTER the message: for them the pin must not render; for the
    # other participant it must. Two people, same group, different pinned bars — by design.
    Repo.query!(
      "UPDATE conversation_participants SET cleared_before = now() + interval '1 hour' " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conversation, cleared]
    )

    assert list!(conversation, cleared) == []
    assert [_] = list!(conversation, fresh)
  end

  @tag :postgres_integration
  test "(e) THE FK IS GONE — and re-adding it is exactly what broke pinning" do
    [sender, _viewer] = users = [user!(), user!()]
    conversation = conversation!(users)
    m = scylla_only_message(conversation, sender)

    # Proof of the deploy order: re-create 092's constraint inside this sandbox transaction and the
    # very same insert dies 23503 — new code WITHOUT the 095 migration turns today's clean 404 into
    # a constraint raise. Migration first, then code.
    Repo.query!(
      "ALTER TABLE message_pins ADD CONSTRAINT pins_fk_reenacted " <>
        "FOREIGN KEY (message_id) REFERENCES messages (message_id) ON DELETE CASCADE",
      []
    )

    assert_raise Postgrex.Error, ~r/foreign_key|pins_fk_reenacted/, fn ->
      Repo.query!(
        "INSERT INTO message_pins (conversation_id, message_id, pinned_by) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid)",
        [conversation, m.message_id, sender]
      )
    end

    Repo.query!("ALTER TABLE message_pins DROP CONSTRAINT pins_fk_reenacted", [])

    # Without the constraint (production state after 095): the same insert, via the real path.
    assert {:ok, %{pinned: true}} = pin!(conversation, m.message_id, sender)
  end

  @tag :postgres_integration
  test "a store OUTAGE is an error, never a silently empty bar" do
    [sender, viewer] = users = [user!(), user!()]
    conversation = conversation!(users)
    m = scylla_only_message(conversation, sender)
    assert {:ok, _} = pin!(conversation, m.message_id, sender)

    Application.put_env(:message_service, :message_store_adapter, DownStore)

    assert {:error, :message_store_unavailable} =
             Pins.list_pins(%{"conversation_id" => conversation, "user_id" => viewer})

    assert {:error, :message_store_unavailable} =
             pin!(conversation, Ecto.UUID.generate(), sender)
  end

  @tag :postgres_integration
  test "cross-conversation pinning still refused — the authorization-shaped clause survives" do
    [sender, other_owner] = [user!(), user!()]
    mine = conversation!([sender])
    theirs = conversation!([other_owner])
    foreign = scylla_only_message(theirs, other_owner)

    assert {:error, :message_not_found} = pin!(mine, foreign.message_id, sender)
  end
end
