defmodule ConversationService.WallpaperSettingsTest do
  @moduledoc """
  Shared chat wallpaper (117) — the store half, on real SQL.

  Pinned here: the AUTHORIZATION SPLIT (DMs — either participant; groups — the same owner/admin rule
  as every other conversation setting, so MUT-2's "any member changes a locked group" mutation must
  fail loudly); the VALIDATION whitelist (kind=photo refused exactly like an unknown kind — photos
  are device-local by design; ranges enforced; unknown keys stripped by construction); and the READ
  path — the conversation DETAIL response carries `wallpaper` for both types, nil when unset, because
  the persisted setting (not the live frame) is the source of truth.
  """
  use ExUnit.Case, async: false

  alias ConversationService.Conversations
  alias ConversationService.Participants
  alias ConversationService.Repo

  @wallpaper %{
    "kind" => "pattern",
    "id" => "doodle_07",
    "background" => "sunset",
    "intensity" => 0.18,
    "dim" => 0.2
  }

  # --- authorization -------------------------------------------------------------------------------

  @tag :postgres_integration
  test "DM: EITHER participant may set it, and the other side reads it from the detail fetch" do
    {a, b, dm} = dm!()

    assert {:ok, %{wallpaper: stored}} = set!(dm, b, @wallpaper)
    assert stored == @wallpaper

    # The OTHER participant's detail fetch — the read path both clients use on chat open.
    assert {:ok, detail} =
             Conversations.get_conversation(%{"conversation_id" => dm, "user_id" => a})

    assert detail.wallpaper == @wallpaper
  end

  @tag :postgres_integration
  test "GROUP: a plain member is refused with the settings rule's own code; the owner succeeds" do
    {owner, member, group} = group!()

    assert {:error, :participant_forbidden} = set!(group, member, @wallpaper)

    assert {:ok, %{wallpaper: @wallpaper}} = set!(group, owner, @wallpaper)
  end

  @tag :postgres_integration
  test "NON-MEMBER and UNKNOWN conversation both refuse (the gateway collapses both to one 404)" do
    {_a, _b, dm} = dm!()
    stranger = user!()

    assert {:error, :participant_not_found} = set!(dm, stranger, @wallpaper)
    assert {:error, :conversation_not_found} = set!(Ecto.UUID.generate(), stranger, @wallpaper)
  end

  # --- validation ----------------------------------------------------------------------------------

  @tag :postgres_integration
  test "kind=photo is refused EXACTLY like an unknown kind — photos are device-local" do
    {_a, b, dm} = dm!()

    photo = set!(dm, b, %{"kind" => "photo", "id" => "local_1"})
    unknown = set!(dm, b, %{"kind" => "sparkles"})

    assert {:error, :wallpaper_invalid} = photo
    assert photo == unknown
  end

  @tag :postgres_integration
  test "out-of-range fields refuse; in-range persist" do
    {_a, b, dm} = dm!()

    assert {:error, :wallpaper_invalid} = set!(dm, b, %{"kind" => "pattern", "intensity" => 0.9})
    assert {:error, :wallpaper_invalid} = set!(dm, b, %{"kind" => "pattern", "dim" => 0.61})
    assert {:error, :wallpaper_invalid} = set!(dm, b, %{"kind" => "solid", "color" => ""})

    assert {:error, :wallpaper_invalid} =
             set!(dm, b, %{"kind" => "scene", "id" => String.duplicate("x", 65)})

    assert {:ok, _} = set!(dm, b, %{"kind" => "solid", "color" => "#101418", "dim" => 0.6})
  end

  @tag :postgres_integration
  test "unknown keys are STRIPPED by construction — the column only ever holds the documented shape" do
    {a, b, dm} = dm!()

    assert {:ok, %{wallpaper: stored}} =
             set!(dm, b, Map.merge(@wallpaper, %{"sneaky" => "payload", "url" => "http://x"}))

    # KEY-SET: exactly the whitelist subset that was sent, nothing else.
    assert stored |> Map.keys() |> Enum.sort() == ["background", "dim", "id", "intensity", "kind"]

    assert {:ok, detail} =
             Conversations.get_conversation(%{"conversation_id" => dm, "user_id" => a})

    assert detail.wallpaper |> Map.keys() |> Enum.sort() ==
             ["background", "dim", "id", "intensity", "kind"]
  end

  # --- clearing + the read contract ----------------------------------------------------------------

  @tag :postgres_integration
  test "null CLEARS; unset reads as nil — and the detail key-set is pinned" do
    {a, b, dm} = dm!()

    {:ok, before_set} = Conversations.get_conversation(%{"conversation_id" => dm, "user_id" => a})
    assert before_set.wallpaper == nil

    {:ok, _} = set!(dm, b, @wallpaper)
    assert {:ok, %{wallpaper: nil}} = set!(dm, a, nil)

    {:ok, cleared} = Conversations.get_conversation(%{"conversation_id" => dm, "user_id" => a})
    assert cleared.wallpaper == nil

    # THE DETAIL SERIALISER, whole-key-set — a partial match cannot fail on a missing key, and the
    # Android slice consumes these keys verbatim.
    assert cleared |> Map.keys() |> Enum.sort() == [
             :app_id,
             :call_start_permission,
             :conversation_id,
             :created_by,
             :e2ee_disabled,
             :e2ee_off_pending,
             :group_avatar_media_id,
             :only_admins_can_send,
             :participants,
             :secret,
             :sharing_disabled,
             :tenant_id,
             :title,
             :type,
             :wallpaper
           ]
  end

  @tag :postgres_integration
  test "wallpaper does NOT disturb the group-governance settings beside it" do
    {owner, _member, group} = group!()

    {:ok, _} =
      Participants.set_group_settings(%{
        "conversation_id" => group,
        "actor_user_id" => owner,
        "only_admins_can_send" => true,
        "call_start_permission" => "admins_only"
      })

    {:ok, _} = set!(group, owner, @wallpaper)

    {:ok, detail} =
      Conversations.get_conversation(%{"conversation_id" => group, "user_id" => owner})

    assert detail.only_admins_can_send == true
    assert detail.call_start_permission == "admins_only"
    assert detail.wallpaper == @wallpaper
  end

  # --- helpers -------------------------------------------------------------------------------------

  defp set!(conversation_id, actor, wallpaper) do
    Participants.set_wallpaper(%{
      "conversation_id" => conversation_id,
      "actor_user_id" => actor,
      "wallpaper" => wallpaper
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
        "title" => "Wallpaper Squad",
        "created_by" => owner,
        "participant_user_ids" => [member]
      })

    {owner, member, conv.conversation_id}
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, email, status) VALUES ($1, $2, 'active')",
      [Ecto.UUID.dump!(id), "wallpaper-#{System.unique_integer([:positive])}@example.test"]
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
