defmodule Engram.Folders.Drift do
  @moduledoc """
  The two folder-reference drift predicates, as SQL text, in ONE place.

  Each is the predicate of a partial index (`notes_unresolved_folder` of
  20261103130200, `attachments_folder_ref_stale` of 20261103140100). Postgres
  uses a partial index only for a query that carries the same text, so every
  reader of the drift (`Engram.Bookkeeping.Drain`, `DataMigrations.FolderTable`,
  the folder readers in `Engram.Notes` and `Engram.Attachments`) takes it from
  here. The migrations keep their own literal (a migration must not call app
  code); `drift_test.exs` pins each literal to this text.

  Unqualified column names: use the fragments only on a single-table query.
  """
  import Ecto.Query

  @notes_unresolved_sql "kind = 'note' AND deleted_at IS NULL AND folder_ref_id IS NULL " <>
                          "AND octet_length(folder_ciphertext) > 16"

  # The second test is `Engram.Folders.Rows.unreadable_attachment_stamp/1`'s
  # shape (a 0 byte before the nonce): a row FolderTable could not read.
  @attachments_stale_sql "deleted_at IS NULL AND folder_ref_stamp IS DISTINCT FROM path_nonce " <>
                           "AND folder_ref_stamp IS DISTINCT FROM ('\\x00'::bytea || path_nonce)"

  @doc "A live note in a non-root folder with no `folder_ref_id`: `notes_unresolved_folder`."
  @spec notes_unresolved_sql() :: String.t()
  def notes_unresolved_sql, do: @notes_unresolved_sql

  @doc "A live attachment whose reference stamp is not its path nonce: `attachments_folder_ref_stale`."
  @spec attachments_stale_sql() :: String.t()
  def attachments_stale_sql, do: @attachments_stale_sql

  # Local macros, so Ecto sees the literal (a `fragment` needs one at
  # compile time), as `Engram.Links` does for its stamp test.
  defmacrop notes_unresolved_fragment,
    do: quote(do: fragment(unquote(@notes_unresolved_sql)))

  defmacrop attachments_stale_fragment,
    do: quote(do: fragment(unquote(@attachments_stale_sql)))

  @doc "`notes_unresolved_sql/0` as a `dynamic` (single-table notes query)."
  @spec notes_unresolved() :: Ecto.Query.dynamic_expr()
  def notes_unresolved, do: dynamic([], notes_unresolved_fragment())

  @doc "`attachments_stale_sql/0` as a `dynamic` (single-table attachments query)."
  @spec attachments_stale() :: Ecto.Query.dynamic_expr()
  def attachments_stale, do: dynamic([], attachments_stale_fragment())
end
