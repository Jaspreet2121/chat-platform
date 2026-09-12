defmodule ConversationService.SharingSettingsTest do
  @moduledoc """
  "Restrict sharing" (120) — the store half, on real SQL.

  Mirrors the wallpaper's shape exactly, and pins the three things the Android client consumes:

    * the AUTHORIZATION SPLIT — a DM's either participant, a group's owner/admin only (a plain
      member changing a group-wide setting is the mutation this must catch);
    * the VALUE — only a real boolean, because a string that silently became `true` is a setting the
      user believes is on and the server believes is off;
    * the READ — `sharing_disabled` is ALWAYS on the conversation detail, false included. The client
      hides the toggle while the key is absent, so `false` and `absent` are different wire shapes
      and must never collapse into one.
  """
  use ExUnit.Case, async: false

  alias ConversationService.Conversations
  alias ConversationService.Participants
  alias ConversationService.Repo

  # --- authorization -------------------------------------------------------------------------------

  @tag :postgres_integration
  test "DM: EITHER participant may restrict it, and the other side reads it from the detail fetch" do
    {a, b, dm} = dm!()

    assert {:ok, %{conversation_id: ^dm, sharing_disabled: true}} = set!(dm, b, true)

    assert {:ok, detail} =
             Conversations.get_conversation(%{"conversation_id" => dm, "user_id" => a})

    assert detail.sharing_disabled == true
  end

  @tag :postgres_integration
  test "GROUP: a plain member is REFUSED with the settings rule's own code; the owner succeeds" do
    {owner, member, group} = group!()

    assert {:error, :participant_forbidden} = set!(group, member, true),
           "a plain group member changed a conversation-wide setting — the same rule that guards " <>
             "only_admins_can_send and the wallpaper must guard this one"

    assert {:ok, %{sharing_disabled: true}} = set!(group, owner, true)

    assert {:ok, detail} =
             Conversations.get_conversation(%{"conversation_id" => group, "user_id" => member})

    assert detail.sharing_disabled == true
  end

  @tag :postgres_integration
  test "NON-MEMBER and UNKNOWN conversation both refuse (the gateway collapses both to one 404)" do
    {_a, _b, dm} = dm!()
    stranger = user!()

    assert {:error, :participant_not_found} = set!(dm, stranger, true)
    assert {:error, :conversation_not_found} = set!(Ecto.UUID.generate(), stranger, true)
  end

  # --- the value -----------------------------------------------------------------------------------

  @tag :postgres_integration
  test "ONLY a real boolean — a truthy string is refused, not coerced" do
    {_a, b, dm} = dm!()

    for bad <- ["true", "1", 1, nil, %{}, "yes"] do
      assert {:error, :sharing_invalid} = set!(dm, b, bad),
             "#{inspect(bad)} was accepted — a coerced value means the user and the server " <>
               "disagree about whether sharing is off"
    end
  end

  @tag :postgres_integration
  test "turning it back OFF persists false — not a reverted-to-absent row" do
    {a, b, dm} = dm!()

    {:ok, _} = set!(dm, b, true)
    assert {:ok, %{sharing_disabled: false}} = set!(dm, a, false)

    {:ok, detail} = Conversations.get_conversation(%{"conversation_id" => dm, "user_id" => a})
    assert detail.sharing_disabled == false
  end

  # --- the read contract ---------------------------------------------------------------------------

  @tag :postgres_integration
  test "ALWAYS PRESENT: a conversation that never had a settings row still carries false" do
    {a, _b, dm} = dm!()

    {:ok, detail} = Conversations.get_conversation(%{"conversation_id" => dm, "user_id" => a})

    assert Map.has_key?(detail, :sharing_disabled),
           "the key was absent for an unrestricted chat — the client reads absence as 'the server " <>
             "does not support this' and hides the toggle entirely"

    assert detail.sharing_disabled == false
  end

  @tag :postgres_integration
  test "a settings row created by ANOTHER setting still reads sharing_disabled as false" do
    {owner, _member, group} = group!()

    {:ok, _} =
      Participants.set_group_settings(%{
        "conversation_id" => group,
        "actor_user_id" => owner,
        "only_admins_can_send" => true
      })

    {:ok, detail} =
      Conversations.get_conversation(%{"conversation_id" => group, "user_id" => owner})

    assert detail.sharing_disabled == false
    assert detail.only_admins_can_send == true
  end

  @tag :postgres_integration
  test "sharing does NOT disturb the settings beside it (wallpaper, group governance)" do
    {owner, _member, group} = group!()

    {:ok, _} =
      Participants.set_group_settings(%{
        "conversation_id" => group,
        "actor_user_id" => owner,
        "only_admins_can_send" => true,
        "call_start_permission" => "admins_only"
      })

    {:ok, _} =
      Participants.set_wallpaper(%{
        "conversation_id" => group,
        "actor_user_id" => owner,
        "wallpaper" => %{"kind" => "solid", "color" => "#101418"}
      })

    {:ok, _} = set!(group, owner, true)

    {:ok, detail} =
      Conversations.get_conversation(%{"conversation_id" => group, "user_id" => owner})

    assert detail.sharing_disabled == true
    assert detail.only_admins_can_send == true
    assert detail.call_start_permission == "admins_only"
    assert detail.wallpaper == %{"kind" => "solid", "color" => "#101418"}
  end

  # --- helpers -------------------------------------------------------------------------------------

  defp set!(conversation_id, actor, value) do
    Participants.set_sharing_disabled(%{
      "conversation_id" => conversation_id,
      "actor_user_id" => actor,
      "sharing_disabled" => value
    })
  end

  defp dm! do
    a = user!()
    b = user!()

    {:ok, conv} =
      Conversations.create_conversation(%{
        "type" => "direct",
        "created_by" => a,
        "participant_user_ids" => [b]
      })

    {a, b, conv.conversation_id}
  end

  defp group! do
    owner = user!()
    member = user!()

    {:ok, conv} =
      Conversations.create_conversation(%{
        "type" => "group",
        "title" => "Sharing Squad",
        "created_by" => owner,
        "participant_user_ids" => [member]
      })

    {owner, member, conv.conversation_id}
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, phone_number, status) VALUES ($1::text::uuid, $2, 'active')",
      [id, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    start_repo!(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous)
    end)

    :ok
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, pid} -> Process.unlink(pid) && :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
