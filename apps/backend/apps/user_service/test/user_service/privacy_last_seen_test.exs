defmodule UserService.PrivacyLastSeenTest do
  @moduledoc """
  `last_seen_visibility/1` — the visibility the presence gate reads. Defaults to the conservative "contacts"
  when there's no settings row; returns the stored value when there is.
  """
  use UserService.DataCase, async: false

  alias UserService.Privacy

  setup do
    prev = Application.get_env(:user_service, :user_profile_persistence, false)
    Application.put_env(:user_service, :user_profile_persistence, true)
    on_exit(fn -> Application.put_env(:user_service, :user_profile_persistence, prev) end)
    :ok
  end

  defp visibility(user_id) do
    {:ok, %{last_seen_visibility: v}} = Privacy.last_seen_visibility(%{"user_id" => user_id})
    v
  end

  test "no settings row → the conservative default 'contacts'" do
    assert visibility(Ecto.UUID.generate()) == "contacts"
  end

  test "returns the stored visibility" do
    user_id = Ecto.UUID.generate()

    # Raw insert (the FK needs a users_auth row; the changeset requires every field). "nobody" is the value
    # the presence gate must honour.
    Repo.query!(
      "INSERT INTO users_auth (id, app_id, external_id, password_hash, created_at, updated_at) VALUES ($1::text::uuid,'00000000-0000-0000-0000-000000000001'::uuid,$2,'x',now(),now())",
      [user_id, "ext-#{user_id}"]
    )

    Repo.query!(
      "INSERT INTO user_privacy_settings (user_id, last_seen_visibility, profile_photo_visibility, read_receipts_enabled, created_at, updated_at) VALUES ($1::text::uuid,'nobody','contacts',true,now(),now())",
      [user_id]
    )

    assert visibility(user_id) == "nobody"
  end

  test "a missing user_id → the default, never a crash" do
    assert {:ok, %{last_seen_visibility: "contacts"}} = Privacy.last_seen_visibility(%{})
  end
end
