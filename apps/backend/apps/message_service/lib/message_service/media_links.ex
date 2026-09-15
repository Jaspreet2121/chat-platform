defmodule MessageService.MediaLinks do
  @moduledoc """
  A media message carries its own download link: `metadata.media.download_url` (presigned GET) +
  `metadata.media.download_url_expires_at` (ISO-8601, 15 minutes). Attached to the create ack —
  which is what the REST response, the socket `message_created` frame and the inbox row carry — and
  to every row of a timeline page. Nothing is ever STORED: the link is minted at read time, on every
  read, so a page loaded now carries a live URL and a page loaded tomorrow carries a fresh one.

  ## Client rule

  Use `metadata.media.download_url` if `download_url_expires_at` is still in the future; otherwise
  (expired, or the key is absent) fall back to `GET /api/v1/media/:id/download`, which stays exactly
  as it was. The endpoint is the source of truth; the inline link only removes one round trip.

  ## What gets a link — and what does not

    * `message_type == "media"` with a `media_id`, not deleted → linked.
    * VIEW-ONCE media → NEVER linked. The download endpoint mints view-once URLs with a 120 s TTL and
      denies the moment the recipient opens (`ApiGatewayWeb.MediaAuthz`); a 15-minute URL sitting in
      the timeline payload would outlive that deny. View-once keeps the endpoint path.
    * SEALED messages → no link, because the server has no media_id to presign: the descriptor lives
      inside the ciphertext envelope and `media_id` is forced nil on the sealed create path
      (`MessageService.Messages`). The sealed client keeps its presign endpoint.

  ## Cost and failure

  ONE `SharedInfra.MediaClient.get_download_urls/1` call per page (or per create), never one per row:
  media-service answers it with one tenant-scoped query and N local SigV4 signatures. The link is
  ADDITIVE and fail-soft: an adapter without the callback (older media image, partial test double),
  a transport error or an unknown app leaves the page exactly as it was — logged once, never failed.
  Applied AFTER the Kafka publish, so no event, projection, webhook or push ever carries a
  short-lived capability URL.
  """

  require Logger

  alias MessageService.ConversationRow

  # 15 minutes — the media service's default; passed explicitly so the payload's TTL does not drift
  # if that default ever changes (shorten-only on the media side, so it can never lengthen it).
  @url_expires_seconds 900

  @doc "The presign TTL requested for inline links, in seconds."
  def url_expires_seconds, do: @url_expires_seconds

  @doc "Attach links to ONE message response (the create ack). Returns the response unchanged on any failure."
  def attach(%{} = response), do: response |> List.wrap() |> attach_all() |> hd()

  @doc "Attach links to every eligible message of a page, with one presign call per conversation."
  def attach_all(responses) when is_list(responses) do
    responses
    |> Enum.filter(&eligible?/1)
    |> Enum.group_by(&aget(&1, :conversation_id))
    |> Enum.reduce(responses, fn {conversation_id, eligible}, acc ->
      media_ids = eligible |> Enum.map(&aget(&1, :media_id)) |> Enum.uniq()

      case links_for(conversation_id, media_ids) do
        {:ok, by_id} -> Enum.map(acc, &put_links(&1, conversation_id, by_id))
        :skip -> acc
      end
    end)
  end

  def attach_all(other), do: other

  @doc false
  def eligible?(response) do
    aget(response, :message_type) == "media" and is_binary(aget(response, :media_id)) and
      aget(response, :media_id) != "" and aget(response, :view_once) != true and
      is_nil(aget(response, :deleted_at))
  end

  defp links_for(conversation_id, media_ids) do
    case app_id(conversation_id) do
      nil ->
        :skip

      app_id ->
        started = System.monotonic_time(:millisecond)

        result =
          SharedInfra.MediaClient.get_download_urls(%{
            "media_ids" => media_ids,
            "app_id" => app_id,
            "url_expires_seconds" => @url_expires_seconds
          })

        case result do
          {:ok, reply} ->
            by_id = reply |> aget(:downloads) |> index_by_media_id()

            Logger.info(
              "media links attached conversation_id=#{conversation_id} requested=#{length(media_ids)} " <>
                "linked=#{map_size(by_id)} ms=#{System.monotonic_time(:millisecond) - started}"
            )

            {:ok, by_id}

          {:error, reason} ->
            Logger.warning(
              "media links skipped conversation_id=#{conversation_id} requested=#{length(media_ids)} " <>
                "reason=#{inspect(reason)}"
            )

            :skip
        end
    end
  rescue
    error ->
      Logger.warning(
        "media links skipped conversation_id=#{conversation_id} requested=#{length(media_ids)} " <>
          "reason=#{inspect(error)}"
      )

      :skip
  end

  defp app_id(conversation_id) do
    case ConversationRow.fetch(conversation_id) do
      {:ok, %{app_id: app_id}} when is_binary(app_id) and app_id != "" -> app_id
      _ -> nil
    end
  end

  defp index_by_media_id(downloads) when is_list(downloads) do
    Enum.reduce(downloads, %{}, fn download, acc ->
      media_id = aget(download, :media_id)
      url = aget(download, :download_url)
      expires_at = aget(download, :expires_at)

      if is_binary(media_id) and is_binary(url) and is_binary(expires_at),
        do: Map.put(acc, media_id, %{download_url: url, expires_at: expires_at}),
        else: acc
    end)
  end

  defp index_by_media_id(_other), do: %{}

  defp put_links(response, conversation_id, by_id) do
    with true <- eligible?(response),
         true <- aget(response, :conversation_id) == conversation_id,
         {:ok, %{download_url: url, expires_at: expires_at}} <-
           Map.fetch(by_id, aget(response, :media_id)) do
      metadata =
        case aget(response, :metadata) do
          %{} = metadata -> metadata
          _ -> %{}
        end

      media = %{"download_url" => url, "download_url_expires_at" => expires_at}
      Map.put(response, metadata_key(response), Map.put(metadata, "media", media))
    else
      _ -> response
    end
  end

  defp metadata_key(response),
    do: if(Map.has_key?(response, "metadata"), do: "metadata", else: :metadata)

  defp aget(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp aget(_other, _key), do: nil
end
