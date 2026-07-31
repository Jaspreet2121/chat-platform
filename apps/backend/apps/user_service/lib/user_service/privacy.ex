defmodule UserService.Privacy do
  @moduledoc """
  User privacy settings boundary — the real read/write over `user_privacy_settings`.

  Every read (get_privacy, last_seen_visibility) falls back to the column DEFAULTS ("contacts" visibility,
  receipts on) for a user with no settings row or when persistence is off — the conservative default (never
  "everyone"). Writes are SPARSE: only the keys present in the attrs change; the rest keep their stored value
  (or the default when creating a first row). Enum values are validated by the schema changeset.
  """

  alias UserService.PrivacyStore
  alias UserService.Schemas.UserPrivacySettings

  @type privacy_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @keys ~w(last_seen_visibility profile_photo_visibility read_receipts_enabled discoverable_by_phone)

  @callback get_privacy(privacy_attrs()) :: result()
  @callback update_privacy(privacy_attrs()) :: result()
  @callback last_seen_visibility(privacy_attrs()) :: result()

  @doc "A user's full privacy settings — real values from the store, defaults for no-row/persistence-off."
  def get_privacy(attrs) do
    {:ok, privacy_map(user_id(attrs))}
  end

  @doc """
  Sparse update: only the keys present are changed; the rest keep their stored value (defaults when creating a
  first row). Empty body → `:privacy_empty` (the endpoint maps to 400). An invalid enum / non-boolean →
  `:privacy_invalid_value` (400). Persistence off → `:privacy_unavailable`. Returns the FULL updated settings.
  """
  def update_privacy(attrs) do
    user_id = user_id(attrs)
    changes = sparse_changes(attrs)

    cond do
      not (is_binary(user_id) and user_id != "") -> {:error, :privacy_invalid_value}
      changes == %{} -> {:error, :privacy_empty}
      not user_profile_persistence_enabled?() -> {:error, :privacy_unavailable}
      true -> upsert(user_id, changes)
    end
  end

  @doc """
  A user's `last_seen_visibility` ∈ {everyone, contacts, nobody} — read by PresenceAuthz to gate who may see
  their online state. Defaults to "contacts" (never "everyone") for no row / persistence off. Returns
  `{:ok, %{last_seen_visibility: v}}`.
  """
  def last_seen_visibility(attrs) do
    {:ok, %{last_seen_visibility: privacy_map(user_id(attrs)).last_seen_visibility}}
  end

  @doc "The plain settings map for a user (real values or defaults) — reused by the profile (`me`) assembly."
  def privacy_map(user_id) do
    if user_profile_persistence_enabled?() and is_binary(user_id) and user_id != "" do
      case safe_get(user_id) do
        %UserPrivacySettings{} = row -> to_map(row)
        _ -> placeholder_privacy()
      end
    else
      placeholder_privacy()
    end
  end

  def placeholder_privacy do
    %{
      last_seen_visibility: "contacts",
      profile_photo_visibility: "contacts",
      read_receipts_enabled: true,
      discoverable_by_phone: true
    }
  end

  # --- internals ---

  defp upsert(user_id, changes) do
    case PrivacyStore.get_privacy_settings(user_id) do
      %UserPrivacySettings{} = row ->
        row
        |> PrivacyStore.update_privacy_settings(changes)
        |> result()

      _ ->
        # No row yet → create one, defaulting the untouched keys (the changeset validate_requires all three).
        defaults_with_id(user_id, changes)
        |> PrivacyStore.create_privacy_settings()
        |> result()
    end
  rescue
    _ -> {:error, :privacy_unavailable}
  end

  defp result({:ok, %UserPrivacySettings{} = row}), do: {:ok, to_map(row)}
  # A changeset error is ALWAYS a bad enum / non-boolean here (required-ness is satisfied by the row/defaults).
  defp result({:error, _changeset}), do: {:error, :privacy_invalid_value}

  defp defaults_with_id(user_id, changes) do
    %{
      "last_seen_visibility" => "contacts",
      "profile_photo_visibility" => "contacts",
      "read_receipts_enabled" => true,
      "discoverable_by_phone" => true
    }
    |> Map.merge(changes)
    |> Map.put("user_id", user_id)
  end

  # Only the recognised keys, string-keyed (as they arrive over the internal API). Unknown keys are ignored.
  # Uses has_key? (NOT `||`) so a legitimate `read_receipts_enabled: false` is a real change, not "absent".
  defp sparse_changes(attrs) do
    Enum.reduce(@keys, %{}, fn key, acc ->
      cond do
        Map.has_key?(attrs, key) -> Map.put(acc, key, Map.get(attrs, key))
        Map.has_key?(attrs, safe_atom(key)) -> Map.put(acc, key, Map.get(attrs, safe_atom(key)))
        true -> acc
      end
    end)
  end

  defp to_map(%UserPrivacySettings{} = row) do
    %{
      last_seen_visibility: row.last_seen_visibility,
      profile_photo_visibility: row.profile_photo_visibility,
      read_receipts_enabled: row.read_receipts_enabled,
      discoverable_by_phone: row.discoverable_by_phone
    }
  end

  defp user_id(attrs), do: Map.get(attrs, "user_id") || Map.get(attrs, :user_id)

  defp safe_get(user_id) do
    PrivacyStore.get_privacy_settings(user_id)
  rescue
    _ -> nil
  end

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__missing__
  end

  defp user_profile_persistence_enabled? do
    Application.get_env(:user_service, :user_profile_persistence, false) ||
      System.get_env("USER_PROFILE_DB_BACKED") == "true"
  end
end
