defmodule MessageService.StatusAudienceTest do
  @moduledoc """
  `Statuses.audience_of/1` — the recipient set of a `status_updated` event — is the feed's audience
  predicate turned around, and must admit EXACTLY the users the feed would: predating shared
  conversation (each side's own joined_at, left_at a live deny), no block either way, the owner's
  mode ('except' minus, 'only' intersect). Never the owner. Answers for a tombstoned post (a delete
  event goes to those who could see it). Real SQL (`@tag :postgres_integration`).
  """
  use MessageService.DataCase, async: false

  alias MessageService.Statuses

  setup do
    prev = %{
      persistence: Application.get_env(:message_service, :message_persistence, false),
      sweep: Application.get_env(:message_service, :status_sweep_async)
    }

    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :status_sweep_async, false)

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev.persistence)

      if prev.sweep == nil,
        do: Application.delete_env(:message_service, :status_sweep_async),
        else: Application.put_env(:message_service, :status_sweep_async, prev.sweep)
    end)

    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, 'x', now(), now())",
      [id, "#{id}@test.local"]
    )

    id
  end

  defp shared_conversation!(a, b, seconds_ago \\ 3600) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'direct', $2::text::uuid, 'active', now(), now())",
      [id, a]
    )

    for u <- [a, b], do: join!(id, u, seconds_ago)
    id
  end

  defp join!(conversation_id, user_id, seconds_ago) do
    Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'member', now() - make_interval(secs => $3))",
      [conversation_id, user_id, seconds_ago]
    )
  end

  defp leave!(conversation_id, user_id) do
    Repo.query!(
      "UPDATE conversation_participants SET left_at = now() " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [conversation_id, user_id]
    )
  end

  defp block!(blocker, blocked) do
    Repo.query!(
      "INSERT INTO user_blocks (blocker_user_id, blocked_user_id) VALUES ($1::text::uuid, $2::text::uuid)",
      [blocker, blocked]
    )
  end

  defp post!(owner) do
    {:ok, post} =
      Statuses.post_status(%{"owner_user_id" => owner, "kind" => "text", "body" => "hi"})

    post.status_id
  end

  defp audience(owner, status_id) do
    Statuses.audience_of(%{"owner_user_id" => owner, "status_id" => status_id})
  end

  @tag :postgres_integration
  test "a predating shared conversation admits the peer; a stranger and the owner are never in the set" do
    owner = user!()
    peer = user!()
    _stranger = user!()
    shared_conversation!(owner, peer)
    status_id = post!(owner)

    assert {:ok, %{user_ids: [^peer]}} = audience(owner, status_id)
  end

  @tag :postgres_integration
  test "PREDATING: a late joiner is out; LEAVING is a live deny; a group counts its members once" do
    owner = user!()
    early = user!()
    late = user!()
    leaver = user!()
    conversation = shared_conversation!(owner, early)
    join!(conversation, leaver, 3600)
    other = shared_conversation!(owner, early)
    _ = other
    status_id = post!(owner)
    # Joined AFTER the post (joined_at in the future relative to created_at).
    join!(conversation, late, -60)
    leave!(conversation, leaver)

    assert {:ok, %{user_ids: [^early]}} = audience(owner, status_id)
  end

  @tag :postgres_integration
  test "MUT-2 guard: a block in EITHER direction removes the user, live" do
    owner = user!()
    blocked_by_owner = user!()
    blocker = user!()
    clean = user!()
    for u <- [blocked_by_owner, blocker, clean], do: shared_conversation!(owner, u)
    status_id = post!(owner)
    block!(owner, blocked_by_owner)
    block!(blocker, owner)

    assert {:ok, %{user_ids: [^clean]}} = audience(owner, status_id)
  end

  @tag :postgres_integration
  test "MODES: 'except' subtracts the list, 'only' intersects it — and never widens past the contacts rule" do
    owner = user!()
    a = user!()
    b = user!()
    outsider = user!()
    for u <- [a, b], do: shared_conversation!(owner, u)
    status_id = post!(owner)

    {:ok, _} =
      Statuses.set_audience(%{"user_id" => owner, "mode" => "except", "member_user_ids" => [a]})

    assert {:ok, %{user_ids: [^b]}} = audience(owner, status_id)

    {:ok, _} =
      Statuses.set_audience(%{
        "user_id" => owner,
        "mode" => "only",
        "member_user_ids" => [a, outsider]
      })

    # 'only' lists the outsider, but they share no predating conversation: still out.
    assert {:ok, %{user_ids: [^a]}} = audience(owner, status_id)

    {:ok, _} =
      Statuses.set_audience(%{"user_id" => owner, "mode" => "contacts", "member_user_ids" => []})

    assert {:ok, %{user_ids: ids}} = audience(owner, status_id)
    assert Enum.sort(ids) == Enum.sort([a, b])
  end

  @tag :postgres_integration
  test "a TOMBSTONED post still answers its audience (the delete event's recipients); unknown or foreign → not_found" do
    owner = user!()
    peer = user!()
    shared_conversation!(owner, peer)
    status_id = post!(owner)

    assert {:ok, %{deleted: true}} =
             Statuses.delete_status(%{"owner_user_id" => owner, "status_id" => status_id})

    assert {:ok, %{user_ids: [^peer]}} = audience(owner, status_id)
    assert {:error, :status_not_found} = audience(peer, status_id)
    assert {:error, :status_not_found} = audience(owner, Ecto.UUID.generate())
    assert {:error, :status_not_found} = audience(owner, "not-a-uuid")
  end
end
