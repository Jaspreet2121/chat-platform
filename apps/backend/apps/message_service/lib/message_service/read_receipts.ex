defmodule MessageService.ReadReceipts do
  @moduledoc """
  READ-RECEIPT RECIPROCITY (46e4e7f), defined ONCE for every surface that discloses "who consumed your
  content, and when":

      disclosed(viewer → owner) = enabled(viewer) AND enabled(owner)

  The two halves live here so no consumer can restate them:

    * `read_receipts_on/1` — the VIEWER half, a macro expanded inside Ecto query macros (a reader/viewer
      counts + appears iff they kept receipts ON; no privacy row → NULL → default enabled).
    * `viewer_sees_read_receipts?/1` — the OWNER half, ONE lookup per read (an owner who turned receipts
      OFF is disclosed nothing). Fail-OPEN: a privacy read glitch shows receipts rather than hiding
      everyone's.

  Consumers (all three expand the SAME macro — the count, the list, and status views cannot drift):
    1. `MessageStore.PostgresAdapter.receipt_counts/2` — read_by_count (the aggregate);
    2. `MessageStore.PostgresAdapter.message_info/1` — the per-message reader list;
    3. `MessageService.Statuses` — status viewer lists + the owner's view counts (082, commit 2).

  Extracted from PostgresAdapter (where it was a `defmacrop`, unreachable outside that module) precisely
  so the status surface could consume it instead of re-expressing the rule in raw SQL.
  """

  alias MessageService.Repo

  @doc """
  The VIEWER half, for use inside an Ecto query where `ps` is a binding on `user_privacy_settings`
  (LEFT-joined on the viewer/reader): true when they kept read receipts on.

      |> join(:left, [v], ps in "user_privacy_settings", on: ps.user_id == v.viewer_user_id)
      |> where([v, ps], read_receipts_on(ps))
  """
  defmacro read_receipts_on(ps) do
    quote do
      is_nil(unquote(ps).read_receipts_enabled) or unquote(ps).read_receipts_enabled
    end
  end

  @doc """
  The OWNER half: does this user still SEE receipts/viewers at all? One lookup per read. No row / true /
  null → yes (default). Fail-OPEN on any error.
  """
  def viewer_sees_read_receipts?(viewer) when is_binary(viewer) and viewer != "" do
    case Ecto.UUID.dump(viewer) do
      {:ok, uid} ->
        case Repo.query!(
               "SELECT read_receipts_enabled FROM user_privacy_settings WHERE user_id = $1",
               [uid]
             ) do
          %Postgrex.Result{rows: [[false]]} -> false
          _ -> true
        end

      :error ->
        true
    end
  rescue
    _ -> true
  end

  def viewer_sees_read_receipts?(_viewer), do: true
end
