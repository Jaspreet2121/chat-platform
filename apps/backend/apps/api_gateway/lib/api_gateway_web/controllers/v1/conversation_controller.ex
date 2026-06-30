defmodule ApiGatewayWeb.V1.ConversationController do
  @moduledoc """
  Public `/v1` conversation create — scoped to the authenticated app_id. Participants are the
  integrator's external end-user ids, resolved-or-created within this app. Reuses
  conversation_service's create/find_or_create_direct (direct chats stay idempotent per pair per app).
  """

  use ApiGatewayWeb, :controller

  alias ApiGatewayWeb.ErrorResponse

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
