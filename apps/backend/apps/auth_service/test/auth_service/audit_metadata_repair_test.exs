defmodule AuthService.AuditMetadataRepairTest do
  @moduledoc """
  Migration 133 turns double-encoded audit metadata back into objects — and touches nothing else.

  Every audit row written before 2026-09-25 holds its metadata as a JSON STRING containing JSON,
  because the writer encoded a map and then handed it to a jsonb-typed parameter that encoded it
  again. The migration is run here against the real file so the repair, its idempotence, and its
  refusal to touch rows it does not recognise are all pinned by the same SQL that will run on prod.
  """
  use AuthService.DataCase, async: false

  @migration Path.expand(
               "../../../shared_infra/priv/schema/133_audit_metadata_repair.sql",
               __DIR__
             )

  defp insert!(metadata_literal) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO audit_logs (id, action, target_type, target_id, metadata) " <>
        "VALUES ($1::text::uuid, 'test.repair', 'user', 't', #{metadata_literal})",
      [id]
    )

    id
  end

  defp metadata(id) do
    %Postgrex.Result{rows: [[type, reason]]} =
      Repo.query!(
        "SELECT jsonb_typeof(metadata), metadata->>'reason' FROM audit_logs WHERE id = $1::text::uuid",
        [id]
      )

    {type, reason}
  end

  defp run_migration!, do: Repo.query!(File.read!(@migration), [])

  @tag :postgres_integration
  test "a double-encoded row becomes the object it was meant to be" do
    id = insert!(~s('"{\\"reason\\":\\"abuse report\\"}"'::jsonb))
    assert {"string", nil} = metadata(id)

    run_migration!()

    assert {"object", "abuse report"} = metadata(id)
  end

  @tag :postgres_integration
  test "a row already an object, and a string that is not JSON, are left exactly as they were" do
    object = insert!(~s('{"reason":"kept"}'::jsonb))
    stray = insert!(~s('"just a note"'::jsonb))

    run_migration!()
    # Idempotent: a second run has nothing to do and nothing to break.
    run_migration!()

    assert {"object", "kept"} = metadata(object)
    assert {"string", nil} = metadata(stray)
  end
end
