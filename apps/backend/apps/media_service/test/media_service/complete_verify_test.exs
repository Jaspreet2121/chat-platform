defmodule MediaService.CompleteVerifyTest do
  @moduledoc """
  The size the client CLAIMS at create is advisory — the bytes go straight to storage via a presigned PUT, so
  the backend never sees them. `verify_uploaded_size/1` is the real security boundary: HEAD the object, cap on
  the MEASURED size, delete + refuse if over.

  Docker-free: swaps in a stub Storage adapter, so the verification logic (cap, delete-on-reject, fail-closed)
  runs without MinIO. The end-to-end complete → DB flip needs Postgres AND MinIO (see the report).
  """
  use ExUnit.Case, async: false

  alias MediaService.Media
  alias MediaService.Schemas.MediaAsset

  @key "media/owner/abc/file.bin"

  defmodule StorageStub do
    @moduledoc false
    @behaviour MediaService.Storage

    def start_link,
      do:
        Agent.start_link(fn -> %{head: {:error, :verify_failed}, deleted: [], delete: :ok} end,
          name: __MODULE__
        )

    def set_head(result), do: Agent.update(__MODULE__, &Map.put(&1, :head, result))
    def set_delete(result), do: Agent.update(__MODULE__, &Map.put(&1, :delete, result))
    def deleted, do: Agent.get(__MODULE__, & &1.deleted)

    @impl true
    def head_object(_attrs), do: Agent.get(__MODULE__, & &1.head)

    @impl true
    def delete_object(%{"object_key" => key}) do
      Agent.update(__MODULE__, fn s -> %{s | deleted: s.deleted ++ [key]} end)
      Agent.get(__MODULE__, & &1.delete)
    end

    @impl true
    def create_upload(_attrs), do: {:error, :media_storage_unavailable}
    @impl true
    def complete_upload(_attrs), do: {:error, :media_storage_unavailable}
    @impl true
    def get_download_url(_attrs), do: {:error, :media_storage_unavailable}
  end

  setup do
    start_supervised!(%{id: StorageStub, start: {StorageStub, :start_link, []}})
    prev = Application.get_env(:media_service, :media_storage_adapter)
    Application.put_env(:media_service, :media_storage_adapter, StorageStub)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:media_service, :media_storage_adapter, prev),
        else: Application.delete_env(:media_service, :media_storage_adapter)
    end)

    :ok
  end

  # An asset row as it exists between create and complete: size_bytes is the client's CLAIM.
  defp asset(claimed_size),
    do: %MediaAsset{object_key: @key, size_bytes: claimed_size, status: "created"}

  defp max_bytes do
    case System.get_env("MEDIA_MAX_SIZE_BYTES") do
      nil -> 100 * 1024 * 1024
      raw -> String.to_integer(raw)
    end
  end

  test "an object within the cap verifies, returning the REAL size (not the claim)" do
    # The client claimed 100 bytes; the object is actually 4 MB — under the cap, so it's fine, and the REAL
    # size is what comes back (this is what gets written to the row, so usage metering can't be gamed).
    real = 4 * 1024 * 1024
    StorageStub.set_head({:ok, %{object_key: @key, size_bytes: real}})

    assert {:ok, ^real} = Media.verify_uploaded_size(asset(100))
    assert StorageStub.deleted() == []
  end

  test "THE HOLE: claim tiny, upload huge → :media_too_large, and the object is DELETED" do
    over = max_bytes() + 1
    StorageStub.set_head({:ok, %{object_key: @key, size_bytes: over}})

    # The row claims 100 bytes and passed create_upload's cap. The MEASURED size is what refuses it.
    assert {:error, :media_too_large} = Media.verify_uploaded_size(asset(100))

    # The bytes are removed — nothing permanent lands, and the asset never becomes ready.
    assert StorageStub.deleted() == [@key]
  end

  test "a FAILED delete still refuses the upload (best-effort cleanup; orphan > usable over-cap asset)" do
    StorageStub.set_head({:ok, %{object_key: @key, size_bytes: max_bytes() + 1}})
    StorageStub.set_delete({:error, :media_storage_unavailable})

    # Cleanup failing must NOT turn into a successful complete.
    assert {:error, :media_too_large} = Media.verify_uploaded_size(asset(100))
    assert StorageStub.deleted() == [@key]
  end

  test "exactly AT the cap is accepted (boundary)" do
    at = max_bytes()
    StorageStub.set_head({:ok, %{object_key: @key, size_bytes: at}})

    assert {:ok, ^at} = Media.verify_uploaded_size(asset(at))
    assert StorageStub.deleted() == []
  end

  test "the PUT never happened → :upload_not_found (nothing to complete), no delete attempted" do
    StorageStub.set_head({:error, :upload_not_found})

    assert {:error, :upload_not_found} = Media.verify_uploaded_size(asset(100))
    assert StorageStub.deleted() == []
  end

  test "FAIL CLOSED: an unverifiable object (transport error) is never accepted" do
    StorageStub.set_head({:error, :verify_failed})

    assert {:error, :verify_failed} = Media.verify_uploaded_size(asset(100))
    assert StorageStub.deleted() == []
  end

  test "ready_changeset writes the MEASURED size over the client's claim" do
    real = 7_777
    changeset = MediaAsset.ready_changeset(asset(100), real, DateTime.utc_now())

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :size_bytes) == real
    assert Ecto.Changeset.get_change(changeset, :status) == "ready"
  end
end
