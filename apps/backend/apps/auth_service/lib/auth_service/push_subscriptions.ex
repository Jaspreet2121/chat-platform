defmodule AuthService.PushSubscriptions do
  @moduledoc """
  Web-push subscription storage (Phase 1). A subscription is a per-browser device credential, so it
  lives with identity: UPSERT by the globally-unique endpoint (re-subscribing from the same browser
  updates keys/owner), DELETE by endpoint scoped to the CALLER's own rows. The notification service
  reads this table directly to deliver pushes; nothing here sends anything.
  """

  alias AuthService.Repo

  def save_subscription(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, endpoint} <- required(attrs, "endpoint"),
         {:ok, p256dh} <- required(attrs, "p256dh"),
         {:ok, auth} <- required(attrs, "auth") do
      if persistence_enabled?() do
        Repo.query!(
          "INSERT INTO push_subscriptions (user_id, endpoint, p256dh, auth, user_agent) " <>
            "VALUES ($1::text::uuid, $2, $3, $4, $5) " <>
            "ON CONFLICT (endpoint) DO UPDATE SET user_id = EXCLUDED.user_id, " <>
            "p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth, user_agent = EXCLUDED.user_agent, " <>
            "last_used_at = now()",
          [user_id, endpoint, p256dh, auth, attrs["user_agent"]]
        )

        {:ok, %{saved: true}}
      else
        {:ok, %{saved: true}}
      end
    end
  rescue
    _ -> {:error, :auth_invalid}
  end

  def delete_subscription(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, endpoint} <- required(attrs, "endpoint") do
      if persistence_enabled?() do
        Repo.query!(
          "DELETE FROM push_subscriptions WHERE endpoint = $1 AND user_id = $2::text::uuid",
          [endpoint, user_id]
        )
      end

      {:ok, %{deleted: true}}
    end
  rescue
    _ -> {:error, :auth_invalid}
  end

  defp required(attrs, key) do
    case attrs[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_request}
    end
  end

  defp persistence_enabled?, do: AuthService.Sessions.persistence_enabled?()
end
