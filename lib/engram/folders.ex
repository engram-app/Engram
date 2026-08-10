defmodule Engram.Folders do
  @moduledoc """
  Coordinates folder-level operations that span both notes and attachments.

  Folder rename/delete/move must touch the `notes` AND `attachments` tables.
  `Engram.Notes` cannot depend on `Engram.Attachments` (the latter already
  depends on the former), so this module is the single place that fans a folder
  op out to both. Every *content-mutating* folder surface — folder **rename**,
  **batch-delete**, and **batch-move** (REST + MCP) — routes through here so no
  caller can forget the attachment leg.

  The marker-only single DELETE (`DELETE /api/folders/:path`) intentionally does
  NOT route through here: it calls `Notes.delete_folder_marker/3`, which removes
  just the folder marker and deletes no content — the notes AND attachments under
  that path stay live. With nothing deleted, there is nothing to cascade, so a
  coordinator hop would be a no-op.

  Consistency is atomic across BOTH tables: each op wraps the notes leg and the
  attachment leg in a single `Repo.transaction` (the legs' own
  `Repo.with_tenant` transactions nest as savepoints). Any leg error rolls both
  tables back together, so a conflict can never leave notes moved with
  attachments stranded (Bug 3/6).

  Broadcasts are deferred to commit (Fix #1): `atomic/1` brackets the outer
  transaction with `Engram.Sync.Broadcast.deferred/1`, so every per-item
  `note_changed` event the legs emit (routed through `Sync.Broadcast.emit/3`)
  is buffered and flushed ONLY after the outer transaction commits — and
  discarded entirely on rollback. No more phantom delete/upsert events for a
  cascade that a later conflict unwinds.
  """

  alias Engram.Attachments
  alias Engram.Crypto
  alias Engram.Logger.Metadata
  alias Engram.Notes
  alias Engram.Repo
  alias Engram.Sync.Broadcast

  require Logger

  @type counts :: %{notes: non_neg_integer(), attachments: non_neg_integer()}

  # Bug 3 / Bug 6 — atomicity across both tables.
  #
  # Each leg (`Notes.*`, `Attachments.*`) runs its own `Repo.with_tenant`
  # transaction internally. We wrap BOTH legs in a single outer
  # `Repo.transaction` so the inner leg transactions nest as savepoints, and on
  # ANY leg error we `Repo.rollback/1`, unwinding BOTH tables together. Without
  # this, a clean notes leg followed by an attachment-leg conflict left notes
  # moved while attachments stayed put (a permanent split / half-delete).
  #
  # The outer transaction deliberately sets NO tenant context — each leg's own
  # `with_tenant` sets and tears down `app.current_tenant` per call. Because the
  # legs run sequentially (not nested under one another), they don't clobber
  # each other's tenant key.
  defp atomic(fun) do
    # Defer cascade broadcasts until AFTER the outer transaction resolves.
    # Each leg's per-item broadcast routes through `Sync.Broadcast.emit/3`,
    # which — because the buffer is active inside `deferred/1` — buffers rather
    # than fires. `deferred/1` then flushes the buffer iff the transaction
    # committed ({:ok, _}) or discards it on rollback ({:error, _}). The buffer
    # brackets the transaction (OUTSIDE the txn) so emits happen INSIDE it via
    # the legs → buffered → flushed post-commit / discarded post-rollback. This
    # closes the phantom-event window where an inner leg's broadcast fired as
    # its savepoint released, before a later attachment conflict rolled the data
    # back, leaving clients with delete/upsert events that never persisted.
    Broadcast.deferred(fn ->
      Repo.transaction(fn ->
        case fun.() do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
  end

  @spec rename(map(), map(), String.t(), String.t()) :: {:ok, counts()} | {:error, term()}
  def rename(user, vault, old_folder, new_folder) do
    atomic(fn ->
      with {:ok, notes} <- Notes.rename_folder(user, vault, old_folder, new_folder),
           {:ok, atts} <- Attachments.rename_folder(user, vault, old_folder, new_folder) do
        {:ok, %{notes: notes, attachments: atts}}
      end
    end)
  end

  @doc """
  Deletes a folder and, when `recursive: true`, everything under it.

  Empty-only by default: if the folder holds any live notes or attachments
  (recursively), returns `{:error, {:not_empty, %{notes: n, attachments: a}}}`
  so an AI caller must explicitly opt into destruction. Nested empty folder
  markers are not content — they are cleared along with the target marker.

  Returns `{:ok, %{notes: n, attachments: a}}` where n/a are the content rows
  removed (0/0 when only a marker was cleared, or the folder did not exist).
  """
  @spec delete(map(), map(), String.t(), keyword()) ::
          {:ok, counts()} | {:error, {:not_empty, counts()} | term()}
  def delete(user, vault, folder, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, false)
    folder = String.trim_trailing(folder, "/")

    if folder == "" do
      {:error, :root_delete_refused}
    else
      # SCAN ONCE, then decide and delete from that same row set.
      #
      # This closes the TOCTOU gap outright rather than narrowing it. The old
      # shape counted and cascaded through separate full-vault scans: even
      # inside one transaction, READ COMMITTED gives each statement its own
      # snapshot, so a row a concurrent same-user txn committed between them
      # was visible to the delete but not to the count — deleted without
      # `recursive: true` ever having covered it. The guard now decides on
      # EXACTLY the rows `delete_scanned`/`delete_scanned_paths` will remove,
      # so there is no second observation to disagree with the first. It also
      # halves the work: each side previously ran two full fetch+batch-decrypt
      # passes over the vault per delete.
      #
      # Both scans are `with`-chained (not hard-matched) so a crypto fault or a
      # non-ok tenant-unwrap tuple propagates as an error instead of
      # MatchError-ing — and, more importantly, so neither can answer "empty"
      # for "I couldn't tell". The notes leg guards that via `get_dek` plus a
      # reload for a stale user struct; the attachment leg reports how many
      # rows it could not read, which the guard below treats as "unknown"
      # rather than "absent".
      #
      # Reload ONCE here: both scan and apply need a DEK-bearing struct, and
      # each reloads defensively. Doing it up front makes those no-ops.
      user = Crypto.fresh_user(user)

      atomic(fn ->
        with {:ok, note_rows} <- Notes.scan_folders(user, vault, [folder]),
             {:ok, %{paths: att_paths, undecryptable: unreadable}} <-
               Attachments.scan_folder_paths(user, vault, folder) do
          # Markers are not content: an empty folder matches only its own
          # marker row, which must not make it look non-empty.
          notes = Enum.count(note_rows, &(&1.kind == "note"))
          atts = length(att_paths)

          cond do
            notes + atts > 0 and not recursive ->
              {:error, {:not_empty, %{notes: notes, attachments: atts}}}

            # We cannot PROVE this folder is empty. An unreadable row has no
            # decryptable path, so it may or may not live here — and the
            # non-recursive delete exists precisely to refuse when content
            # might be present. `recursive: true` is an explicit "remove
            # whatever is under here", so it proceeds (and logs the orphans
            # below) rather than leaving the user with no way to delete
            # anything at all.
            unreadable > 0 and not recursive ->
              {:error, {:unverifiable, %{undecryptable_attachments: unreadable}}}

            true ->
              log_orphaned_attachments(user, vault, folder, unreadable)
              delete_scanned(user, vault, note_rows, att_paths, notes)
          end
        end
      end)
    end
  end

  defp delete_scanned(user, vault, note_rows, att_paths, notes) do
    with {:ok, %{deleted: _}} <- Notes.delete_scanned(user, vault, note_rows),
         {:ok, a} <- Attachments.delete_scanned_paths(user, vault, att_paths) do
      # Notes.delete_folder's `deleted` includes folder markers; report
      # the content-note count already computed so the caller sees
      # notes, not markers.
      {:ok, %{notes: notes, attachments: a}}
    end
  end

  # A recursive/batch delete removes what it can READ. Rows whose path will not
  # decrypt are invisible to both the scan and the delete, so they survive as
  # live rows under a path whose folder marker is gone. That is the safe
  # direction — better an orphan than a silent destruction — but it must not be
  # silent, or the user is told a folder is gone while its storage still bills.
  defp log_orphaned_attachments(_user, _vault, _folder, 0), do: :ok

  defp log_orphaned_attachments(user, vault, folder, count) do
    Logger.warning(
      "folder delete: undecryptable attachments left orphaned",
      Metadata.with_category(:warning, :crypto,
        user_id: user.id,
        vault_id: vault.id,
        folder_depth: length(String.split(folder, "/")),
        orphaned: count
      )
    )

    :ok
  end

  @spec batch_delete(map(), map(), [String.t()]) :: {:ok, counts()} | {:error, term()}
  def batch_delete(_user, _vault, []), do: {:ok, %{notes: 0, attachments: 0}}

  def batch_delete(user, vault, marker_ids) do
    atomic(fn ->
      with {:ok, %{deleted: notes, folders: folders}} <-
             Notes.batch_delete_folders(user, vault, marker_ids),
           {:ok, atts} <- delete_attachments_for(user, vault, folders) do
        {:ok, %{notes: notes, attachments: atts}}
      end
    end)
  end

  @spec batch_move(map(), map(), [String.t()], String.t() | {:path, String.t()}) ::
          {:ok, counts()} | {:error, term()}
  def batch_move(_user, _vault, [], _target), do: {:ok, %{notes: 0, attachments: 0}}

  def batch_move(user, vault, marker_ids, target) do
    atomic(fn ->
      with {:ok, %{moved: notes, pairs: pairs}} <-
             Notes.batch_move_folders(user, vault, marker_ids, target),
           {:ok, atts} <- rename_attachments_for(user, vault, pairs) do
        {:ok, %{notes: notes, attachments: atts}}
      end
    end)
  end

  # Perf (finding #9): scan the vault's attachments ONCE per batch op, then
  # partition the decrypted paths across the N folders — instead of calling
  # `Attachments.delete_folder`/`rename_folder` per folder, each of which ran its
  # own full `list_attachments` scan (O(N × total_attachments) wasted DB work).
  # The pre-filtered paths feed the leaner explicit-list attachment entry points
  # (`batch_delete/3` for delete; `move_folder_pairs/3` for rename) so the whole
  # batch still commits inside the coordinator's `atomic/1` transaction.

  defp delete_attachments_for(_user, _vault, []), do: {:ok, 0}

  defp delete_attachments_for(user, vault, folders) do
    # Batch delete is recursive by nature — it removes the named folders and
    # everything under them — so it takes the same reading as `recursive: true`
    # above: delete what is readable, and LOG what is not. Silently returning
    # `attachments: 0` while live rows survive under a deleted marker is the
    # orphaning this whole change exists to stop, and it reached here through
    # the tolerant listing.
    with {:ok, metas, unreadable} <- Attachments.scan_with_drops(user, vault) do
      prefixes = Enum.map(folders, &folder_prefix/1)

      paths =
        metas
        |> Enum.map(& &1.path)
        |> Enum.filter(fn path -> Enum.any?(prefixes, &String.starts_with?(path, &1)) end)

      log_orphaned_attachments(user, vault, Enum.join(folders, ","), unreadable)

      {:ok, %{deleted: n}} = Attachments.batch_delete(user, vault, paths)
      {:ok, n}
    end
  end

  defp rename_attachments_for(_user, _vault, []), do: {:ok, 0}

  defp rename_attachments_for(user, vault, pairs) do
    with {:ok, metas} <- Attachments.list_attachments(user, vault) do
      move_pairs =
        Enum.flat_map(metas, fn %{path: old_path} ->
          case rename_target(old_path, pairs) do
            {:ok, new_path} -> [{old_path, new_path}]
            :no_match -> []
          end
        end)

      Attachments.move_folder_pairs(user, vault, move_pairs)
    end
  end

  defp folder_prefix(folder), do: String.trim_trailing(folder, "/") <> "/"

  # Maps a decrypted attachment path to its new path under whichever {old, new}
  # folder pair owns it. When a batch selects BOTH a parent and a nested child
  # (e.g. `Docs` and `Docs/Sub`), an attachment under the child matches both
  # `old` prefixes. We resolve by LONGEST-PREFIX (most-specific) match (Fix #2):
  # the item belongs to its DEEPEST selected folder, so `Docs/Sub/a.png` follows
  # the `Docs/Sub → …` mapping — deterministically, regardless of pair order
  # (first-match-wins was ambiguous). Mirrors `Attachments.rename_folder/4`'s
  # prefix-slice derivation, preserving nesting.
  #
  # Scoped to the ATTACHMENT leg: aligning the NOTES leg's own
  # overlapping-selection behavior is a separate pre-existing concern.
  #
  # Public under `@doc false` purely as a test seam — going through `batch_move/4`
  # is order-dependent (the notes leg can rewrite the pair set mid-cascade), so a
  # determinism unit test needs to drive the resolver with a fixed pair set.
  @doc false
  @spec resolve_attachment_target(String.t(), [{String.t(), String.t()}]) ::
          {:ok, String.t()} | :no_match
  def resolve_attachment_target(path, pairs), do: rename_target(path, pairs)

  defp rename_target(path, pairs) do
    pairs
    |> Enum.flat_map(fn {old, new} ->
      old = String.trim_trailing(old, "/")
      new = String.trim_trailing(new, "/")
      prefix = old <> "/"

      if String.starts_with?(path, prefix) do
        [{String.length(old), new <> String.slice(path, String.length(old)..-1//1)}]
      else
        []
      end
    end)
    |> case do
      [] -> :no_match
      matches -> {:ok, matches |> Enum.max_by(&elem(&1, 0)) |> elem(1)}
    end
  end
end
