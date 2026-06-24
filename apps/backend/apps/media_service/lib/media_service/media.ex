defmodule MediaService.Media do
  @moduledoc """
  Media upload/download boundary.

  Live MinIO/S3 URL signing is behind the storage adapter boundary and is not
  enabled by default.
  """

  alias MediaService.Storage

  # Kept in sync with the frontend allowedMediaTypes set (apps/web chat page). video/quicktime (.mov)
  # is what Mac screen recordings / iPhone clips use; video/webm + video/x-matroska (.mkv) are common too.
  @allowed_content_types MapSet.new([
                           "image/jpeg",
                           "image/png",
                           "image/webp",
                           "application/pdf",
                           "audio/mpeg",
                           "audio/mp4",
                           "video/mp4",
                           "video/quicktime",
                           "video/webm",
                           "video/x-matroska"
                         ])

  @type media_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback create_upload(media_attrs()) :: result()
  @callback complete_upload(media_attrs()) :: result()
  @callback get_download_url(media_attrs()) :: result()

  def create_upload(attrs) do
    with {:ok, owner_user_id} <- required_attr(attrs, "owner_user_id"),
         {:ok, filename} <- required_attr(attrs, "filename"),
         {:ok, content_type} <- required_content_type(attrs),
         {:ok, size_bytes} <- required_size(attrs) do
      media_id = generate_uuid()
      object_key = object_key(owner_user_id, media_id, filename)
      expires_at = expires_at()

      upload_attrs = %{
        "media_id" => media_id,
        "owner_user_id" => owner_user_id,
        "filename" => filename,
        "content_type" => content_type,
        "size_bytes" => size_bytes,
        "object_key" => object_key,
        "expires_at" => expires_at
      }

      if media_persistence_enabled?() do
        case Storage.create_upload(upload_attrs) do
          {:ok, upload} -> {:ok, upload_response(upload, upload_attrs)}
          {:error, reason} -> {:error, reason}
        end
      else
        {:ok, placeholder_upload_response(upload_attrs)}
      end
    end
  end

  def complete_upload(attrs) do
    with {:ok, media_id} <- required_attr(attrs, "media_id"),
         {:ok, owner_user_id} <- required_attr(attrs, "owner_user_id"),
         {:ok, object_key} <- required_attr(attrs, "object_key") do
      complete_attrs = %{
        "media_id" => media_id,
        "owner_user_id" => owner_user_id,
        "object_key" => object_key
      }

      if media_persistence_enabled?() do
        case Storage.complete_upload(complete_attrs) do
          {:ok, media} -> {:ok, complete_response(media)}
          {:error, reason} -> {:error, reason}
        end
      else
        {:ok, complete_response(complete_attrs)}
      end
    end
  end

  def get_download_url(attrs) do
    with {:ok, media_id} <- required_attr(attrs, "media_id"),
         {:ok, owner_user_id} <- required_attr(attrs, "owner_user_id"),
         {:ok, object_key} <- required_attr(attrs, "object_key") do
      expires_at = expires_at()

      download_attrs = %{
        "media_id" => media_id,
        "owner_user_id" => owner_user_id,
        "object_key" => object_key,
        "expires_at" => expires_at
      }

      if media_persistence_enabled?() do
        case Storage.get_download_url(download_attrs) do
          {:ok, media} -> {:ok, download_response(media, download_attrs)}
          {:error, reason} -> {:error, reason}
        end
      else
        {:ok, placeholder_download_response(download_attrs)}
      end
    end
  end

  def media_persistence_enabled? do
    Application.get_env(:media_service, :media_persistence, false) ||
      System.get_env("MEDIA_DB_BACKED") in ["true", "1", "yes"]
  end

  defp upload_response(upload, attrs) do
    %{
      media_id: upload[:media_id] || attrs["media_id"],
      object_key: upload[:object_key] || attrs["object_key"],
      upload_url: upload[:upload_url],
      expires_at: iso8601(upload[:expires_at] || attrs["expires_at"])
    }
  end

  defp placeholder_upload_response(attrs) do
    %{
      media_id: attrs["media_id"],
      object_key: attrs["object_key"],
      upload_url: "https://media.placeholder.local/uploads/#{attrs["media_id"]}",
      expires_at: iso8601(attrs["expires_at"])
    }
  end

  defp complete_response(media) do
    %{
      media_id: media[:media_id] || media["media_id"],
      status: "ready"
    }
  end

  defp download_response(media, attrs) do
    %{
      media_id: media[:media_id] || attrs["media_id"],
      download_url: media[:download_url],
      expires_at: iso8601(media[:expires_at] || attrs["expires_at"])
    }
  end

  defp placeholder_download_response(attrs) do
    %{
      media_id: attrs["media_id"],
      download_url: "https://media.placeholder.local/downloads/#{attrs["media_id"]}",
      expires_at: iso8601(attrs["expires_at"])
    }
  end

  defp required_content_type(attrs) do
    with {:ok, content_type} <- required_attr(attrs, "content_type"),
         true <- MapSet.member?(@allowed_content_types, content_type) do
      {:ok, content_type}
    else
      _ -> {:error, :media_invalid}
    end
  end

  defp required_size(attrs) do
    with {:ok, size} <- parse_required_size(get_attr(attrs, "size_bytes")) do
      # Single overall cap so a large video can't fill object storage unbounded. Read at RUNTIME via
      # System.get_env (point-of-use, never config.exs-baked) — MEDIA_MAX_SIZE_BYTES overrides the
      # default. Images are additionally compressed client-side, so they're well under this.
      if size > max_size_bytes(), do: {:error, :media_too_large}, else: {:ok, size}
    end
  end

  defp parse_required_size(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp parse_required_size(value) when is_binary(value), do: parse_size(value)
  defp parse_required_size(_), do: {:error, :media_invalid}

  defp parse_size(value) do
    case Integer.parse(value) do
      {size, ""} when size > 0 -> {:ok, size}
      _ -> {:error, :media_invalid}
    end
  end

  # Default 100 MB. Override with MEDIA_MAX_SIZE_BYTES (bytes).
  @default_max_size_bytes 100 * 1024 * 1024

  defp max_size_bytes do
    case System.get_env("MEDIA_MAX_SIZE_BYTES") do
      value when is_binary(value) and value != "" ->
        case Integer.parse(value) do
          {bytes, _rest} when bytes > 0 -> bytes
          _ -> @default_max_size_bytes
        end

      _ ->
        @default_max_size_bytes
    end
  end

  defp required_attr(attrs, key) do
    case get_attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :media_invalid}
    end
  end

  defp object_key(owner_user_id, media_id, filename) do
    "media/#{owner_user_id}/#{media_id}/#{safe_filename(filename)}"
  end

  defp safe_filename(filename) do
    filename
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> case do
      "" -> "upload"
      value -> value
    end
  end

  defp expires_at do
    expires_in_seconds =
      :media_service
      |> Application.get_env(:minio, [])
      |> Keyword.get(:url_expires_seconds, 900)

    DateTime.utc_now()
    |> DateTime.add(expires_in_seconds, :second)
    |> DateTime.truncate(:second)
  end

  defp get_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c = Bitwise.band(c, 0x0FFF) |> Bitwise.bor(0x4000)
    d = Bitwise.band(d, 0x3FFF) |> Bitwise.bor(0x8000)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      c,
      d,
      e
    ])
    |> IO.iodata_to_binary()
    |> String.downcase()
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(value), do: value
end
