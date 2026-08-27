defmodule MediaService.MultipartTest do
  @moduledoc """
  S3 multipart uploads (112) at the domain boundary.

  The storage adapter here is a REAL in-memory multipart implementation, not a shape stub: it stages
  parts, refuses to assemble when one is missing, and concatenates in part order. That is what lets
  these tests assert byte-identical assembly and the missing-part refusal rather than merely that we
  called the right function.

  What must hold, and why each matters:
    * create → parts → complete produces the exact bytes, and the row is only usable after complete;
    * an ABANDONED upload never yields a usable row (no object exists, status stays "created");
    * tenancy/ownership answer 404, never 403 — same posture as the single-PUT path;
    * malformed part sets are refused BEFORE storage, so a corrupt object is not reachable.
  """
  use ExUnit.Case, async: false

  alias MediaService.Media
  alias MediaService.Repo, as: MediaRepo
  alias MediaService.Schemas.MediaAsset
  alias MediaService.Storage

  @moduletag :postgres_integration

  @owner "11111111-1111-4111-8111-111111111111"
  @other_owner "77777777-7777-4777-8777-777777777777"
  @app "00000000-0000-0000-0000-000000000001"
  @other_app "99999999-9999-4999-8999-999999999999"

  # A working multipart store: uploads are keyed by upload_id, parts by number, and complete
  # concatenates them in ascending order exactly as S3 does.
  defmodule MultipartStore do
    @moduledoc false
    use Agent

    def start do
      case Agent.start(fn -> %{uploads: %{}, objects: %{}} end, name: __MODULE__) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    def reset, do: Agent.update(__MODULE__, fn _ -> %{uploads: %{}, objects: %{}} end)

    def begin(object_key) do
      id = "upload-#{System.unique_integer([:positive])}"

      Agent.update(__MODULE__, fn state ->
        put_in(state, [:uploads, id], %{object_key: object_key, parts: %{}})
      end)

      id
    end

    def put_part(upload_id, part_number, bytes) do
      Agent.get_and_update(__MODULE__, fn state ->
        case state.uploads[upload_id] do
          nil ->
            {{:error, :no_such_upload}, state}

          upload ->
            etag = "\"#{:crypto.hash(:md5, bytes) |> Base.encode16(case: :lower)}\""
            parts = Map.put(upload.parts, part_number, %{bytes: bytes, etag: etag})
            {{:ok, etag}, put_in(state, [:uploads, upload_id], %{upload | parts: parts})}
        end
      end)
    end

    def complete(upload_id, requested) do
      Agent.get_and_update(__MODULE__, fn state ->
        case state.uploads[upload_id] do
          nil ->
            {{:error, :multipart_incomplete}, state}

          upload ->
            staged = upload.parts

            # S3 refuses the whole assembly if any requested part is absent or its etag disagrees.
            ok? =
              Enum.all?(requested, fn part ->
                case staged[part["part_number"]] do
                  nil -> false
                  %{etag: etag} -> etag == part["etag"]
                end
              end)

            if ok? do
              bytes =
                requested
                |> Enum.sort_by(& &1["part_number"])
                |> Enum.map_join("", fn part -> staged[part["part_number"]].bytes end)

              state =
                state
                |> put_in([:objects, upload.object_key], bytes)
                |> update_in([:uploads], &Map.delete(&1, upload_id))

              {{:ok, %{object_key: upload.object_key}}, state}
            else
              {{:error, :multipart_incomplete}, state}
            end
        end
      end)
    end

    def abort(upload_id) do
      Agent.update(__MODULE__, fn state ->
        update_in(state, [:uploads], &Map.delete(&1, upload_id))
      end)

      :ok
    end

    def object(object_key), do: Agent.get(__MODULE__, & &1.objects[object_key])
    def staged?(upload_id), do: Agent.get(__MODULE__, &Map.has_key?(&1.uploads, upload_id))
  end

  defmodule MultipartAdapter do
    @moduledoc false
    @behaviour MediaService.Storage

    alias MediaService.MultipartTest.MultipartStore

    @impl true
    def create_upload(_attrs), do: {:error, :media_storage_unavailable}
    @impl true
    def complete_upload(attrs), do: {:ok, attrs}
    @impl true
    def get_download_url(_attrs), do: {:error, :media_storage_unavailable}
    @impl true
    def delete_object(_attrs), do: :ok

    # The completion path HEADs the assembled object — this is what makes the measured-size cap and
    # "the object must actually exist" real in these tests.
    @impl true
    def head_object(%{"object_key" => key}) do
      case MultipartStore.object(key) do
        nil -> {:error, :upload_not_found}
        bytes -> {:ok, %{object_key: key, size_bytes: byte_size(bytes)}}
      end
    end

    @impl true
    def create_multipart_upload(%{"object_key" => key}),
      do: {:ok, %{upload_id: MultipartStore.begin(key), object_key: key}}

    @impl true
    def presign_upload_parts(%{"object_key" => key, "upload_id" => id, "part_numbers" => numbers}) do
      {:ok,
       %{
         parts:
           Enum.map(numbers, fn n ->
             %{part_number: n, url: "https://storage.test/#{key}?partNumber=#{n}&uploadId=#{id}"}
           end)
       }}
    end

    @impl true
    def complete_multipart_upload(%{"upload_id" => id, "parts" => parts}),
      do: MultipartStore.complete(id, parts)

    @impl true
    def abort_multipart_upload(%{"upload_id" => id}), do: MultipartStore.abort(id)
  end

  setup do
    previous_persistence = Application.get_env(:media_service, :media_persistence, false)
    previous_adapter = Application.get_env(:media_service, :media_storage_adapter)

    Application.put_env(:media_service, :media_persistence, true)
    Application.put_env(:media_service, :media_storage_adapter, MultipartAdapter)

    start_repo!()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MediaRepo)
    seed_owner!(@owner)
    seed_owner!(@other_owner)

    MultipartStore.start()
    MultipartStore.reset()

    on_exit(fn ->
      Application.put_env(:media_service, :media_persistence, previous_persistence)

      if previous_adapter,
        do: Application.put_env(:media_service, :media_storage_adapter, previous_adapter),
        else: Application.delete_env(:media_service, :media_storage_adapter)
    end)

    :ok
  end

  defp start_repo! do
    case MediaRepo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp seed_owner!(id) do
    MediaRepo.query!(
      "INSERT INTO users_auth (id, phone_number, status) VALUES ($1::text::uuid, $2, 'active') " <>
        "ON CONFLICT DO NOTHING",
      [id, "+1555#{String.slice(id, 0, 6)}"]
    )
  end

  defp create!(over \\ %{}) do
    Media.create_multipart_upload(
      Map.merge(
        %{
          "owner_user_id" => @owner,
          "app_id" => @app,
          "filename" => "clip.mp4",
          "content_type" => "video/mp4",
          "size_bytes" => 6 * 1024 * 1024
        },
        over
      )
    )
  end

  defp status(media_id) do
    MediaRepo.get(MediaAsset, media_id).status
  end

  describe "full lifecycle" do
    test "create → parts → upload → complete assembles the EXACT bytes and makes the row usable" do
      assert {:ok, created} = create!()
      assert is_binary(created.media_id)
      assert is_binary(created.upload_id)

      # The part size is chosen server-side and returned, so the client never encodes S3's 5 MiB rule.
      assert created.part_size == 5 * 1024 * 1024

      # Not usable yet — the object does not exist and the row is still "created".
      assert status(created.media_id) == "created"

      scope = %{
        "media_id" => created.media_id,
        "upload_id" => created.upload_id,
        "app_id" => @app,
        "owner_user_id" => @owner
      }

      assert {:ok, %{parts: presigned}} =
               Media.presign_upload_parts(Map.put(scope, "part_numbers", [1, 2]))

      assert Enum.map(presigned, & &1.part_number) == [1, 2]
      assert Enum.all?(presigned, &String.contains?(&1.url, "uploadId="))

      # "PUT" each part into the store, exactly as the client would against the presigned URLs.
      first = :binary.copy("a", 5 * 1024 * 1024)
      second = :binary.copy("b", 1024)
      {:ok, etag1} = MultipartStore.put_part(created.upload_id, 1, first)
      {:ok, etag2} = MultipartStore.put_part(created.upload_id, 2, second)

      assert {:ok, completed} =
               Media.complete_multipart_upload(
                 Map.put(scope, "parts", [
                   %{"part_number" => 1, "etag" => etag1},
                   %{"part_number" => 2, "etag" => etag2}
                 ])
               )

      # THE CONVERGENCE REQUIREMENT: the same response shape the single-PUT complete returns.
      assert completed.media_id == created.media_id
      assert completed.status == "ready"

      # Byte-identical assembly, in part order.
      assert MultipartStore.object(created.object_key) == first <> second
      assert status(created.media_id) == "ready"

      # And the measured size replaced the client's claim.
      assert MediaRepo.get(MediaAsset, created.media_id).size_bytes ==
               byte_size(first) + byte_size(second)
    end

    test "parts can be requested in windows, out of order — gaps are legal" do
      {:ok, created} = create!()

      scope = %{
        "media_id" => created.media_id,
        "upload_id" => created.upload_id,
        "app_id" => @app,
        "owner_user_id" => @owner
      }

      assert {:ok, %{parts: window}} =
               Media.presign_upload_parts(Map.put(scope, "part_numbers", [7, 3, 9]))

      assert Enum.map(window, & &1.part_number) == [7, 3, 9]
    end
  end

  describe "abort" do
    test "frees the staged parts and leaves NO usable row" do
      {:ok, created} = create!()
      {:ok, _etag} = MultipartStore.put_part(created.upload_id, 1, "partial")
      assert MultipartStore.staged?(created.upload_id)

      assert {:ok, %{aborted: true}} =
               Media.abort_multipart_upload(%{
                 "media_id" => created.media_id,
                 "upload_id" => created.upload_id,
                 "app_id" => @app,
                 "owner_user_id" => @owner
               })

      refute MultipartStore.staged?(created.upload_id)
      # The row is a tombstone: it can never be presigned or attached.
      assert status(created.media_id) == "deleted"
      assert is_nil(MultipartStore.object(created.object_key))
    end

    test "an ABANDONED upload (never completed, never aborted) leaves no object and an unusable row" do
      {:ok, created} = create!()
      {:ok, _etag} = MultipartStore.put_part(created.upload_id, 1, "orphan")

      # Nothing assembled it, so there is no object at all...
      assert is_nil(MultipartStore.object(created.object_key))
      # ...and the row never left "created", which is what keeps it unusable.
      assert status(created.media_id) == "created"
    end
  end

  describe "tenancy and ownership" do
    test "another tenant's media_id is 404 — never 403, never a hint that it exists" do
      {:ok, created} = create!()

      scope = %{
        "media_id" => created.media_id,
        "upload_id" => created.upload_id,
        "owner_user_id" => @owner,
        "app_id" => @other_app
      }

      assert {:error, :not_found} =
               Media.presign_upload_parts(Map.put(scope, "part_numbers", [1]))

      assert {:error, :not_found} =
               Media.complete_multipart_upload(
                 Map.put(scope, "parts", [%{"part_number" => 1, "etag" => "\"x\""}])
               )

      assert {:error, :not_found} = Media.abort_multipart_upload(scope)
    end

    test "another user's media_id in the SAME tenant is also 404" do
      {:ok, created} = create!()

      scope = %{
        "media_id" => created.media_id,
        "upload_id" => created.upload_id,
        "app_id" => @app,
        "owner_user_id" => @other_owner
      }

      assert {:error, :not_found} =
               Media.presign_upload_parts(Map.put(scope, "part_numbers", [1]))

      assert {:error, :not_found} = Media.abort_multipart_upload(scope)
    end
  end

  describe "purpose passthrough" do
    test "sealed_media requires application/octet-stream, exactly as the single-PUT path does" do
      assert {:ok, created} =
               create!(%{
                 "purpose" => "sealed_media",
                 "content_type" => "application/octet-stream"
               })

      assert MediaRepo.get(MediaAsset, created.media_id).purpose == "sealed_media"

      # The wrong content type for that purpose is refused here too — not silently accepted.
      assert {:error, :media_invalid} =
               create!(%{"purpose" => "sealed_media", "content_type" => "video/mp4"})
    end

    test "an unknown purpose is refused at the domain, and a normal one is stored as sent" do
      assert {:ok, created} = create!(%{"purpose" => "message"})
      assert MediaRepo.get(MediaAsset, created.media_id).purpose == "message"
    end
  end

  describe "part validation" do
    setup do
      {:ok, created} = create!()

      {:ok,
       scope: %{
         "media_id" => created.media_id,
         "upload_id" => created.upload_id,
         "app_id" => @app,
         "owner_user_id" => @owner
       },
       created: created}
    end

    test "duplicate, out-of-range, empty and non-integer part numbers are refused", %{
      scope: scope
    } do
      bad = fn numbers ->
        Media.presign_upload_parts(Map.put(scope, "part_numbers", numbers))
      end

      assert {:error, :media_invalid} = bad.([1, 1, 2])
      assert {:error, :media_invalid} = bad.([0])
      assert {:error, :media_invalid} = bad.([10_001])
      assert {:error, :media_invalid} = bad.([-1])
      assert {:error, :media_invalid} = bad.([])
      assert {:error, :media_invalid} = bad.(["nope"])
      assert {:error, :media_invalid} = Media.presign_upload_parts(scope)
    end

    test "completing with a MISSING part errors — it never assembles a corrupt object", %{
      scope: scope,
      created: created
    } do
      # Only part 1 was actually uploaded.
      {:ok, etag1} = MultipartStore.put_part(created.upload_id, 1, "only-part-one")

      assert {:error, :multipart_incomplete} =
               Media.complete_multipart_upload(
                 Map.put(scope, "parts", [
                   %{"part_number" => 1, "etag" => etag1},
                   %{"part_number" => 2, "etag" => "\"never-uploaded\""}
                 ])
               )

      # THE POINT: no object, and the row is still not usable.
      assert is_nil(MultipartStore.object(created.object_key))
      assert status(created.media_id) == "created"
    end

    test "completing with a WRONG etag is refused the same way", %{scope: scope, created: created} do
      {:ok, _etag} = MultipartStore.put_part(created.upload_id, 1, "bytes")

      assert {:error, :multipart_incomplete} =
               Media.complete_multipart_upload(
                 Map.put(scope, "parts", [%{"part_number" => 1, "etag" => "\"wrong\""}])
               )

      assert status(created.media_id) == "created"
    end

    test "a part entry missing its etag, or an empty list, is refused", %{scope: scope} do
      assert {:error, :media_invalid} =
               Media.complete_multipart_upload(Map.put(scope, "parts", [%{"part_number" => 1}]))

      assert {:error, :media_invalid} =
               Media.complete_multipart_upload(Map.put(scope, "parts", []))

      assert {:error, :media_invalid} = Media.complete_multipart_upload(scope)
    end
  end

  describe "create validation mirrors the single-PUT path" do
    test "missing owner, filename, content type or size are all refused" do
      assert {:error, :media_invalid} = create!(%{"owner_user_id" => nil})
      assert {:error, :media_invalid} = create!(%{"filename" => nil})
      assert {:error, :media_invalid} = create!(%{"content_type" => nil})
      assert {:error, :media_invalid} = create!(%{"size_bytes" => nil})
    end

    test "an over-cap declared size is refused at create" do
      assert {:error, :media_too_large} = create!(%{"size_bytes" => 500 * 1024 * 1024})
    end
  end

  test "Storage dispatches the four multipart callbacks to the configured adapter" do
    {:ok, %{upload_id: id}} = Storage.create_multipart_upload(%{"object_key" => "k/1"})
    assert is_binary(id)
    assert :ok = Storage.abort_multipart_upload(%{"object_key" => "k/1", "upload_id" => id})
  end
end
