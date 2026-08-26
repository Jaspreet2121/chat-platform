defmodule MessageService.WebhookEvents do
  @moduledoc """
  The message.created webhook event, shared by BOTH store adapters so the wire shape cannot drift
  between them (extracted from PostgresAdapter privates in C6). Postgres adapter calls `emit/2`
  inside its transaction (atomic enqueue, unchanged); the Scylla adapter uses `stage/2` before its
  put and promotes after (write-ahead intent — see SharedInfra.WebhookOutbox.stage/4).
  """

  require Logger

  alias MessageService.Repo

  @doc "Same-transaction emit (the Postgres adapter path — unchanged semantics)."
  def emit(app_id, message),
    do:
      with_event(
        app_id,
        message,
        &SharedInfra.WebhookOutbox.emit(Repo, app_id, "message.created", &1)
      )

  @doc "Write-ahead stage (the Scylla adapter path). Returns {:ok, staged_ids}."
  def stage(app_id, message) do
    with_event(app_id, message, fn payload ->
      SharedInfra.WebhookOutbox.stage(Repo, app_id, "message.created", payload)
    end)
    |> case do
      {:ok, ids} -> {:ok, ids}
      :ok -> {:ok, []}
    end
  end

  @doc "The message's authoritative tenant — its conversation's app_id (Postgres, the enduring authority)."
  def conversation_app_id(conversation_id)
      when is_binary(conversation_id) and conversation_id != "" do
    case Repo.query(
           "SELECT app_id::text FROM conversations WHERE id = $1::text::uuid",
           [conversation_id]
         ) do
      {:ok, %{rows: [[app_id]]}} -> app_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def conversation_app_id(_), do: nil

  defp with_event(app_id, message, fun) do
    case sender_external_id(app_id, field(message, :sender_user_id)) do
      {:ok, external_id} ->
        fun.(%{
          "message_id" => field(message, :message_id),
          "conversation_id" => field(message, :conversation_id),
          "sender_external_id" => external_id,
          "message_type" => field(message, :message_type),
          # SECRET CHATS (108): a sealed message's webhook says a message HAPPENED, never what —
          # body is forced nil (it already is in the store; this guard makes the promise explicit)
          # and the sealed envelope never rides a webhook (the payload has no metadata field).
          "body" => payload_body(field(message, :message_type), field(message, :body)),
          "created_at" => to_iso(field(message, :created_at))
        })

      :drop ->
        Logger.warning(
          "message.created webhook dropped: sender #{field(message, :sender_user_id)} has no external_id in app #{app_id}"
        )

        :ok
    end
  end

  defp payload_body("sealed", _body), do: nil
  defp payload_body(_type, body), do: body

  defp sender_external_id(app_id, user_id)
       when is_binary(app_id) and app_id != "" and is_binary(user_id) and user_id != "" do
    case Repo.query(
           "SELECT external_id FROM users_auth " <>
             "WHERE id = $1::text::uuid AND app_id = $2::text::uuid AND external_id IS NOT NULL",
           [user_id, app_id]
         ) do
      {:ok, %{rows: [[external_id]]}} when is_binary(external_id) and external_id != "" ->
        {:ok, external_id}

      _ ->
        :drop
    end
  end

  defp sender_external_id(_app_id, _user_id), do: :drop

  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp to_iso(nil), do: nil
  defp to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp to_iso(other), do: other
end
