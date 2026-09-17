defmodule MessageService.Migration126Test do
  @moduledoc """
  Schema 126 is dual-written byte-identical and re-applies cleanly. Afterwards the CAPS the schema
  is responsible for actually hold against direct SQL — the 200-character CHECK and the bounded,
  unique position that limits added items to 30 — so no code path, present or future, can store
  more than the contract allows.
  """
  use MessageService.DataCase, async: false

  @schema Path.expand("../../../shared_infra/priv/schema/126_checklist_items.sql", __DIR__)
  @init Path.expand(
          "../../../../../../infra/docker/postgres/init/126_checklist_items.sql",
          __DIR__
        )

  defp insert(message_id, item_id, opts) do
    Repo.query(
      "INSERT INTO checklist_items (message_id, item_id, conversation_id, text, position, done) " <>
        "VALUES ($1::text::uuid, $2, $3::text::uuid, $4, $5, false)",
      [
        message_id,
        item_id,
        Ecto.UUID.generate(),
        Keyword.get(opts, :text),
        Keyword.get(opts, :position)
      ]
    )
  end

  @tag :postgres_integration
  test "dual-written byte-identical and re-applies cleanly" do
    assert File.read!(@schema) == File.read!(@init)

    @schema
    |> File.read!()
    |> SharedInfra.Release.statements()
    |> Enum.reject(&(String.upcase(&1) in ["BEGIN", "COMMIT"]))
    |> Enum.each(&Repo.query!(&1, []))

    assert %{rows: [["checklist_items"]]} =
             Repo.query!(
               "SELECT table_name FROM information_schema.tables WHERE table_name = 'checklist_items'"
             )
  end

  @tag :postgres_integration
  test "THE SCHEMA ENFORCES THE CAPS: 200 characters, and positions bounded 1..30 and unique" do
    message = Ecto.UUID.generate()

    # 200 exactly is fine; 201 is refused by the CHECK, not by the code above it.
    assert {:ok, _} = insert(message, "a1", text: String.duplicate("x", 200), position: 1)

    assert {:error, %Postgrex.Error{}} =
             insert(message, "a2", text: String.duplicate("x", 201), position: 2)

    assert {:error, %Postgrex.Error{}} = insert(message, "a3", text: "", position: 3)

    # Position 31 is out of range …
    assert {:error, %Postgrex.Error{}} = insert(message, "a31", text: "over", position: 31)
    assert {:error, %Postgrex.Error{}} = insert(message, "a0", text: "under", position: 0)

    # … and a duplicate position on the same message is refused.
    assert {:error, %Postgrex.Error{}} = insert(message, "dup", text: "again", position: 1)

    # A TICK row (no text, no position) is unconstrained by those — and several may coexist, since
    # the unique index is partial on position IS NOT NULL.
    assert {:ok, _} = insert(message, "i1", text: nil, position: nil)
    assert {:ok, _} = insert(message, "i2", text: nil, position: nil)

    # The same position on a DIFFERENT message is fine.
    assert {:ok, _} = insert(Ecto.UUID.generate(), "a1", text: "other list", position: 1)
  end
end
