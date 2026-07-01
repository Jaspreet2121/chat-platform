defmodule ApiGatewayWeb.V1.ConversationController do
  @moduledoc """
  Public `/v1` conversation create + read — scoped to the authenticated app_id. Participants are the
  integrator's external end-user ids, resolved-or-created within this app. Reuses
  conversation_service's create/find_or_create_direct (direct chats stay idempotent per pair per app).
  Reads resolve ONLY within the caller's app_id — a cross-tenant id is a 404.
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

  # GET /v1/conversations/:id — tenant-scoped read. The conversation resolves ONLY within the caller's
  # app_id (server-derived); a cross-tenant or unknown id both return 404 (no existence reveal).
  def show(conn, %{"id" => conversation_id}) do
    app_id = conn.assigns.v1_app_id

    case SharedInfra.ConversationClient.get_conversation_app(%{
           "conversation_id" => conversation_id,
           "app_id" => app_id
         }) do
      {:ok, conversation} ->
        json(conn, conversation)

      {:error, :conversation_unavailable} ->
        ErrorResponse.service_unavailable(conn, "v1.unavailable")

      _ ->
        ErrorResponse.not_found(conn, "v1.not_found", "Not found")
    end
  end

  def create(conn, params) do
    app_id = conn.assigns.v1_app_id

    with {:ok, type} <- fetch_type(params),
         {:ok, externals} <- fetch_participants(params),
         {:ok, user_ids} <- resolve_participants(app_id, externals),
         {:ok, conversation} <-
           SharedInfra.ConversationClient.create_conversation(%{
             "app_id" => app_id,
             "type" => type,
             "title" => Map.get(params, "title"),
             "created_by" => List.first(user_ids),
             "participant_user_ids" => user_ids
           }) do
      conn
      |> put_status(:created)
      |> json(conversation)
    else
      {:error, :conversation_unavailable} ->
        ErrorResponse.service_unavailable(conn, "v1.unavailable")

      _ ->
        ErrorResponse.invalid_request(conn, "v1.invalid_request")
    end
  end

  defp fetch_type(params) do
    case Map.get(params, "type") do
      type when type in ["direct", "group"] -> {:ok, type}
      _ -> {:error, :invalid_request}
    end
  end

  defp fetch_participants(params) do
    case Map.get(params, "participants") do
      list when is_list(list) and list != [] ->
        if Enum.all?(list, &(is_binary(&1) and &1 != "")),
          do: {:ok, list},
          else: {:error, :invalid_request}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp resolve_participants(app_id, externals) do
    externals
    |> Enum.reduce_while({:ok, []}, fn external_id, {:ok, acc} ->
      case SharedInfra.AuthClient.resolve_external_user(%{
             "app_id" => app_id,
             "external_id" => external_id
           }) do
        {:ok, %{user_id: user_id}} -> {:cont, {:ok, acc ++ [user_id]}}
        _ -> {:halt, {:error, :invalid_request}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.uniq(ids)}
      other -> other
    end
  end
end
