defmodule UserService.Privacy do
  @moduledoc """
  User privacy settings boundary.
  """

  alias UserService.PrivacyStore

  @type privacy_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback get_privacy(privacy_attrs()) :: result()
  @callback last_seen_visibility(privacy_attrs()) :: result()

  def get_privacy(_attrs), do: {:ok, placeholder_privacy()}

  @doc """
  A user's `last_seen_visibility` ∈ {everyone, contacts, nobody} — read by the presence broadcaster/reader to
  gate who may see their online state. Defaults to "contacts" (the column default) when there is no settings
  row or persistence is off — the CONSERVATIVE default (never "everyone"). Returns
  `{:ok, %{last_seen_visibility: v}}`.
  """
  def last_seen_visibility(attrs) do
    user_id = Map.get(attrs, "user_id") || Map.get(attrs, :user_id)

    visibility =
      if user_profile_persistence_enabled?() and is_binary(user_id) and user_id != "" do
        case safe_get(user_id) do
          %{last_seen_visibility: v} when is_binary(v) and v != "" -> v
          _ -> "contacts"
        end
      else
        "contacts"
      end

    {:ok, %{last_seen_visibility: visibility}}
  end

  defp safe_get(user_id) do
    PrivacyStore.get_privacy_settings(user_id)
  rescue
    _ -> nil
  end

  defp user_profile_persistence_enabled? do
    Application.get_env(:user_service, :user_profile_persistence, false) ||
      System.get_env("USER_PROFILE_DB_BACKED") == "true"
  end

  def placeholder_privacy do
    %{
      last_seen_visibility: "contacts",
      profile_photo_visibility: "contacts",
      read_receipts_enabled: true
    }
  end
end
