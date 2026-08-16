defmodule Engram.Links.Rewriter do
  @moduledoc """
  Server-side link rewriter for rename/move propagation
  (issues #648/#1231, Phase 1; markdown syntax #1302).

  When a note or attachment is renamed via REST or MCP, referring notes'
  link targets are rewritten to the new name — both `[[wikilink]]`/
  `![[embed]]` and the markdown `[label](target.md)` form, each occurrence
  coming back in the syntax it was written in. The
  server is the SINGLE rewriter for every origin EXCEPT plugin-origin
  renames (Obsidian's "Automatically update internal links" owns those) —
  exactly one party rewrites, never both. Both CRDT rename legs are wired:
  `genesis_relocate_live` (live row) and `genesis_resurrect`'s
  rename-restore leg (tombstoned row), each behind
  `Notes.crdt_rename_rewrites?/1`.

  POLICY: the server authors only mechanical, semantics-preserving
  transforms — the rewritten target resolves to the same row the old text
  resolved to, and `!` embed markers, `|alias`, `[label]`, and `#anchor`
  segments are preserved verbatim. The server never authors content the
  user didn't write.

  One stated exception (#1302 review): for a markdown occurrence the
  replacement is built from the stored path and re-encoded by `md_encode/1`,
  so the WHOLE target span is normalized to this module's minimal escaping —
  not just the segment that changed. `[x](Old%2CFolder/Note.md)` renamed to
  `Fresh.md` yields `[x](Old,Folder/Fresh.md)`: the folder was untouched but
  its `%2C` is gone. The link resolves to the same row either way, and the
  normalization is idempotent (encode/decode compose to identity, so the
  second pass hits the no-op check), but it IS a byte-level change the user
  did not ask for. Accepted deliberately: preserving per-segment encoding
  would mean diffing the author's raw bytes against the new path segment by
  segment — fiddly logic in the one place a mistake corrupts a note, to
  save a cosmetic difference in a link that already works.

  Rewrites are authored as real Y-updates on the note's canonical doc
  (checkpoint snapshot + `crdt_update_log` tail — `bind/3`'s recipe) and
  appended/broadcast through the SAME persistence path client updates use
  (`CrdtPersistence.update_v1/4`, or the live room when one exists), so
  live editors converge and no content snapshot is ever written.

  Occurrence membership is decided by `Links.pre_rename_winner?/4`
  (pre-rename candidate reconstruction, prefetched once per walk via
  `Links.pre_rename_candidates/5` on the `build_target/5` map), NOT by
  current edge target ids — the `RebindNoteLinks` jobs the same rename
  enqueues race this worker and flip those ids.
  """

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.{Crypto, Repo}
  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Logger.Metadata
  alias Engram.Notes

  alias Engram.Notes.{
    CrdtBridge,
    CrdtDeliver,
    CrdtPersistence,
    CrdtRegistry,
    CrdtUpdateLog,
    Enqueue,
    Note
  }

  alias Yex.Sync.SharedDoc

  require Logger

  @max_persist_attempts 3
  @start_cursor "00000000-0000-0000-0000-000000000000"
  @walk_batch 100

  @note_exts ~w(.md .canvas)

  @doc """
  Plan the target-segment edits for one source note.

  `full_text` is the note's full projected plaintext (what the parser
  runs on); `body` is the Y.Text body (`full_text` minus the frontmatter
  prefix — pass `full_text` itself for plaintext-only callers). Returned
  `rel_start`/`len` are byte offsets into `body`. Idempotent: occurrences
  already carrying the new text plan no edit.
  """
  @spec plan_edits(map(), map(), String.t(), String.t(), map()) :: [map()]
  def plan_edits(user, vault, full_text, body, target) do
    body_start = byte_size(full_text) - byte_size(body)
    old_key = Links.basename_key(target.old_path)

    occurrences =
      full_text
      |> Parser.extract()
      |> Enum.filter(&(Links.basename_key(&1.target) == old_key))

    candidates = if occurrences != [], do: pre_rename_candidates(user, vault, target)

    occurrences
    |> Enum.filter(fn occ ->
      Links.pre_rename_winner?(occ.target, target.old_path, target.id, candidates)
    end)
    |> Enum.flat_map(fn occ ->
      replacement = replacement_target(occ, target)
      rel = occ.target_start - body_start

      cond do
        # Already the new text — idempotent no-op. Compared against the RAW
        # span (not the decoded target) because that is what gets spliced:
        # for a markdown occurrence both sides are percent-encoded here.
        occ.target_raw == replacement -> []
        # Occurrence sits before the body (frontmatter) — the parser already
        # excludes frontmatter, so this is belt-and-suspenders only.
        rel < 0 -> []
        true -> [%{rel_start: rel, len: occ.target_len, old: occ.target_raw, new: replacement}]
      end
    end)
  end

  @doc false
  @spec splice(String.t(), [map()]) :: String.t()
  def splice(text, edits) do
    edits
    |> Enum.sort_by(& &1.rel_start, :desc)
    |> Enum.reduce(text, fn e, acc ->
      binary_part(acc, 0, e.rel_start) <>
        e.new <>
        binary_part(acc, e.rel_start + e.len, byte_size(acc) - e.rel_start - e.len)
    end)
  end

  # build_target/5 prefetches the candidate sets once per job batch (a large
  # walk re-snapshots per cursor-chain job); a
  # hand-built target (unit tests, spec callers) without the key falls back
  # to a per-call fetch — still once per source note, never per occurrence.
  defp pre_rename_candidates(user, vault, target) do
    Map.get_lazy(target, :pre_rename_candidates, fn ->
      Links.pre_rename_candidates(user, vault, target.kind, target.id, target.old_path)
    end)
  end

  # Form rule: bare stays bare when the new basename is unambiguous
  # (target.collision? == false); path-qualified when the occurrence was
  # already path-qualified OR the new basename collides. Casing comes from
  # the actual stored new path. The occurrence's extension form is
  # preserved: `[[Old.md]]` -> `[[Fresh.md]]`, `[[Old]]` -> `[[Fresh]]`;
  # non-note extensions (attachments) always keep theirs.
  #
  # Syntax is preserved too (#1302): a markdown occurrence comes back as a
  # markdown target, percent-encoded. The server never converts one syntax
  # to the other — that would be authoring content the user didn't write.
  defp replacement_target(occ, %{new_path: new_path, collision?: collision?}) do
    %{target: occ_target, form: form} = occ
    qualified? = String.contains?(occ_target, "/") or collision?
    occ_ext = occ_target |> Path.basename() |> Path.extname() |> String.downcase()
    keep_note_ext? = occ_ext in @note_exts

    base = if qualified?, do: new_path, else: Path.basename(new_path)
    new_ext = Path.extname(base)

    replacement =
      if String.downcase(new_ext) in @note_exts and not keep_note_ext? do
        String.replace_suffix(base, new_ext, "")
      else
        base
      end

    if form == :markdown, do: md_encode(replacement), else: replacement
  end

  # Only the characters that would otherwise re-parse the `[..](..)` target
  # into something else: whitespace ends an unbracketed destination, parens
  # end or nest it, `<`/`>` would read as the bracketed-destination form,
  # `#`/`?` start an anchor/query, and a literal `%` would read as an escape.
  # Everything else — `/`, `.`, unicode — stays literal, which is what
  # Obsidian writes.
  @md_escape ~c" ()<>#?%"
  defp md_encode(s), do: URI.encode(s, &(&1 not in @md_escape))

  @doc """
  Build the rewrite target spec for a renamed note/attachment. `old_path`
  is the pre-rename vault-relative path (plaintext, resolved by the caller
  — the worker recovers it from the rename tombstone; it never rides Oban
  args). `new_path`/casing come from the row's CURRENT decrypted path, so
  a rename-of-rename always rewrites toward the latest name.
  """
  @spec build_target(map(), map(), :note | :attachment, binary(), String.t()) ::
          {:ok, map()} | {:error, :target_gone}
  def build_target(user, vault, kind, id, old_path) do
    with {:ok, new_path} <- current_path(user, vault, kind, id) do
      {:ok,
       %{
         kind: kind,
         id: id,
         old_path: old_path,
         new_path: new_path,
         old_basename_hmac: Links.basename_hmac(user, Links.basename_key(old_path)),
         collision?: Links.live_basename_count(user, vault, Links.basename_key(new_path)) > 1,
         # Prefetched ONCE per job batch — plan_edits/5 consults these for
         # every occurrence in every source note instead of re-querying +
         # re-decrypting per occurrence (#1240 review).
         pre_rename_candidates: Links.pre_rename_candidates(user, vault, kind, id, old_path)
       }}
    end
  end

  defp current_path(user, vault, :note, id) do
    row =
      Repo.one(
        from(n in Note,
          where:
            n.id == ^id and n.user_id == ^user.id and n.vault_id == ^vault.id and
              n.kind == "note" and is_nil(n.deleted_at)
        ),
        skip_tenant_check: true
      )

    with %Note{} = note <- row,
         {:ok, %{path: path}} when is_binary(path) <- Crypto.maybe_decrypt_note_fields(note, user) do
      {:ok, path}
    else
      _ -> {:error, :target_gone}
    end
  end

  defp current_path(user, vault, :attachment, id) do
    row =
      Repo.one(
        from(a in Attachment,
          where:
            a.id == ^id and a.user_id == ^user.id and a.vault_id == ^vault.id and
              is_nil(a.deleted_at)
        ),
        skip_tenant_check: true
      )

    with %Attachment{} = att <- row,
         {:ok, %{path: path}} when is_binary(path) <-
           Crypto.maybe_decrypt_attachment_fields(att, user) do
      {:ok, path}
    else
      _ -> {:error, :target_gone}
    end
  end

  @doc """
  Distinct source-note ids with an edge whose `target_basename_hmac`
  matches the renamed row's OLD basename. Keyed on the hmac (indexed), not
  on current edge target ids — `RebindNoteLinks` flips ids concurrently
  but never rewrites the stored hmac/text, so this set is stable however
  the rename-enqueued jobs interleave.
  """
  @spec source_note_ids(map(), map(), binary(), binary(), pos_integer()) :: [binary()]
  def source_note_ids(user, vault, old_basename_hmac, cursor, limit) do
    Repo.all(
      from(l in Engram.Links.NoteLink,
        where:
          l.user_id == ^user.id and l.vault_id == ^vault.id and
            l.target_basename_hmac == ^old_basename_hmac and
            l.source_note_id > ^cursor,
        distinct: true,
        select: l.source_note_id,
        order_by: [asc: l.source_note_id],
        limit: ^limit
      ),
      skip_tenant_check: true
    )
  end

  @doc "Synchronous full walk for a renamed note (spec entry point; the Oban worker chunks the same primitives)."
  @spec rewrite_for_note_rename(map(), map(), binary(), String.t()) ::
          :ok | {:error, :target_gone}
  def rewrite_for_note_rename(user, vault, renamed_note_id, old_path) do
    with {:ok, target} <- build_target(user, vault, :note, renamed_note_id, old_path) do
      walk(user, vault, target, @start_cursor)
    end
  end

  @doc "Attachment variant of `rewrite_for_note_rename/4`."
  @spec rewrite_for_attachment_rename(map(), map(), binary(), String.t()) ::
          :ok | {:error, :target_gone}
  def rewrite_for_attachment_rename(user, vault, attachment_id, old_path) do
    with {:ok, target} <- build_target(user, vault, :attachment, attachment_id, old_path) do
      walk(user, vault, target, @start_cursor)
    end
  end

  defp walk(user, vault, target, cursor) do
    case source_note_ids(user, vault, target.old_basename_hmac, cursor, @walk_batch) do
      [] ->
        :ok

      ids ->
        Enum.each(ids, fn id -> _ = rewrite_source_note(user, vault, id, target) end)
        if length(ids) == @walk_batch, do: walk(user, vault, target, List.last(ids)), else: :ok
    end
  end

  @doc """
  Rewrite one source note. Loads the canonical doc (snapshot + tail),
  plans edits, authors them as ONE Y-text transaction, and persists the
  delta through the client-update path (live room when one exists, direct
  `CrdtPersistence.update_v1/4` append otherwise). Bounded optimistic
  retry when the tail head advances under a roomless append.

  `opts[:before_persist]` — test seam, a 0-arity fun run between edit
  authoring and the roomless head re-check.
  """
  @spec rewrite_source_note(map(), map(), binary(), map(), keyword()) ::
          {:ok, :rewritten | :noop | :skipped} | {:error, term()}
  def rewrite_source_note(user, vault, source_note_id, target, opts \\ []) do
    before_persist = Keyword.get(opts, :before_persist, fn -> :ok end)
    attempt(user, vault, source_note_id, target, before_persist, 1)
  end

  defp attempt(user, vault, source_note_id, target, before_persist, n) do
    case load_doc(user, source_note_id) do
      :skip ->
        {:ok, :skipped}

      {:error, reason} ->
        {:error, reason}

      {:legacy, note, content} ->
        rewrite_legacy(user, vault, note, content, target)

      {:loaded, note, doc, head} ->
        full = CrdtBridge.project_doc(doc)
        body = CrdtBridge.body_of(doc)

        case plan_edits(user, vault, full, body, target) do
          [] ->
            {:ok, :noop}

          edits ->
            sv_before = Yex.encode_state_vector!(doc)
            :ok = apply_edits!(doc, body, edits)
            delta = Yex.encode_state_as_update!(doc, sv_before)
            _ = before_persist.()
            rt = %{target: target, before_persist: before_persist, n: n}
            persist(user, vault, note, doc, delta, head, rt)
        end
    end
  end

  # Snapshot + tail — bind/3's recipe, same as Notes.maybe_merge_crdt/4 and
  # Workers.CheckpointNote.rebuild_detached/3. `head` is {tail row count,
  # max inserted_at} captured in the SAME tenant transaction as the replay.
  defp load_doc(user, note_id) do
    {:ok, doc} = CrdtBridge.doc_from_state(nil)

    {:ok, result} =
      Repo.with_tenant(user.id, fn ->
        case Repo.get(Note, note_id) do
          nil ->
            :skip

          %Note{deleted_at: deleted_at} when deleted_at != nil ->
            :skip

          %Note{} = note ->
            case Crypto.decrypt_crdt_state(note, user) do
              {:error, reason} ->
                {:error, reason}

              {:ok, snapshot} ->
                if is_binary(snapshot), do: :ok = Yex.apply_update(doc, snapshot)
                applied = CrdtPersistence.replay_tail(doc, user, note_id)
                head = tail_head(note_id)

                if is_nil(snapshot) and applied == [] and CrdtBridge.project_doc(doc) == "" do
                  case Crypto.maybe_decrypt_note_fields(note, user) do
                    {:ok, decrypted} -> {:legacy, note, decrypted.content || ""}
                    {:error, reason} -> {:error, reason}
                  end
                else
                  {:loaded, note, doc, head}
                end
            end
        end
      end)

    result
  end

  # Runs inside the caller's Repo.with_tenant (crdt_update_log is RLS-scoped).
  defp tail_head(note_id) do
    Repo.one(
      from(l in CrdtUpdateLog,
        where: l.note_id == ^note_id,
        select: {count(l.id), max(l.inserted_at)}
      )
    )
  end

  @doc false
  @spec apply_edits!(Yex.Doc.t(), String.t(), [map()]) :: :ok
  def apply_edits!(doc, body, edits) do
    text = Yex.Doc.get_text(doc, CrdtBridge.text_name())

    Yex.Doc.transaction(doc, "link_rewrite", fn ->
      edits
      |> Enum.sort_by(& &1.rel_start, :desc)
      |> Enum.each(fn e ->
        off = utf16_len(binary_part(body, 0, e.rel_start))
        len = utf16_len(binary_part(body, e.rel_start, e.len))
        Yex.Text.delete(text, off, len)
        Yex.Text.insert(text, off, e.new)
      end)
    end)

    :ok
  end

  # The doc is offset_kind: :utf16 (CrdtBridge.new_doc/0) — Yex.Text
  # indices are UTF-16 code units, not bytes.
  defp utf16_len(s) do
    s |> :unicode.characters_to_binary(:utf8, {:utf16, :big}) |> byte_size() |> div(2)
  end

  defp persist(user, vault, note, doc, delta, head_at_load, rt) do
    case CrdtRegistry.lookup(note.id) do
      nil ->
        persist_roomless(user, vault, note, doc, delta, head_at_load, rt)

      room ->
        # The room owns the doc and serializes writes; its update_v1 hook
        # appends the delta to the tail-log, broadcasts the frame to every
        # observer, and fans out — the client-update path, verbatim.
        case room_apply(room, note.id, fn room_doc ->
               _ = Yex.apply_update(room_doc, delta)
               :ok
             end) do
          :ok ->
            finish(user, vault, note, doc)

          {:error, :room_gone} ->
            # The room died between lookup and this call — no room ever held
            # the delta, so it was NOT persisted. Falling through to the
            # roomless path is safe: the delta was authored against `doc`
            # (still the same object), and persist_roomless/7 re-checks the
            # tail head before its own append.
            persist_roomless(user, vault, note, doc, delta, head_at_load, rt)
        end
    end
  end

  defp persist_roomless(user, vault, note, doc, delta, head_at_load, rt) do
    {:ok, head_now} = Repo.with_tenant(user.id, fn -> tail_head(note.id) end)

    cond do
      head_now == head_at_load ->
        # Direct call on the documented bare-state-map path: encrypted
        # tail-log append + crdt_head invalidation + FanoutPacer broadcast.
        _ =
          CrdtPersistence.update_v1(
            %{user_id: user.id, vault_id: vault.id, note_id: note.id},
            delta,
            nil,
            doc
          )

        # Roomless append leaves notes.content unmaterialized; the deduped
        # checkpoint worker owns materialization (never a snapshot write here).
        _ =
          Enqueue.enqueue(
            Engram.Workers.CheckpointNote.new(%{
              user_id: user.id,
              vault_id: vault.id,
              note_id: note.id
            }),
            "crdt_checkpoint"
          )

        finish(user, vault, note, doc)

      rt.n < @max_persist_attempts ->
        attempt(user, vault, note.id, rt.target, rt.before_persist, rt.n + 1)

      true ->
        {:error, :head_advanced}
    end
  end

  defp finish(user, vault, note, doc) do
    new_full = CrdtBridge.project_doc(doc)
    :ok = Links.replace_links(user, vault, note.id, Parser.extract(new_full))

    _ =
      case Crypto.maybe_decrypt_note_fields(note, user) do
        {:ok, %{path: path}} when is_binary(path) ->
          CrdtDeliver.announce_ready(user.id, vault.id, path, note.id)

        _ ->
          :ok
      end

    {:ok, :rewritten}
  end

  # Legacy/pre-CRDT row: no Y-text to edit positionally. Route the spliced
  # plaintext through the established non-CRDT-origin write path
  # (upsert_note = convergent diff-merge + broadcast + deliver-out) — a
  # diff-based write, not a snapshot clobber.
  defp rewrite_legacy(user, vault, note, content, target) do
    case plan_edits(user, vault, content, content, target) do
      [] ->
        {:ok, :noop}

      edits ->
        new_text = splice(content, edits)

        with {:ok, %{path: path}} when is_binary(path) <-
               Crypto.maybe_decrypt_note_fields(note, user),
             {:ok, _updated} <-
               Notes.upsert_note(user, vault, %{"path" => path, "content" => new_text}) do
          :ok = Links.replace_links(user, vault, note.id, Parser.extract(new_text))
          {:ok, :rewritten}
        else
          {:ok, _no_path} -> {:error, :path_undecryptable}
          {:error, :version_conflict, _existing} -> {:error, :version_conflict}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Guarded room call. UNLIKE CrdtDeliver.room_apply/3 (which pushes a
  # broadcast AFTER a write already committed to the row — a dead room there
  # only drops a notification), this call to SharedDoc.update_doc/2 IS the
  # write: it's the only place the delta gets appended to the tail-log. A
  # room can die between CrdtRegistry.lookup/1 and this call (auto-exit on
  # last observer disconnect, deploy shutdown, a crash) or the call can time
  # out — every one of those means the delta was NOT persisted, so every
  # exit reason here returns `{:error, :room_gone}` and the caller falls
  # through to a fresh roomless attempt. Silently swallowing and reporting
  # success would durably desync note_links from the doc (see #1231 review).
  defp room_apply(room, note_id, fun) do
    SharedDoc.update_doc(room, fun)
    :ok
  catch
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :room_gone}

    :exit, reason ->
      Logger.error(
        "link rewrite room push exited",
        Metadata.with_category(:error, :sync,
          note_id: note_id,
          reason: Metadata.safe_exit_reason(reason)
        )
      )

      {:error, :room_gone}
  end
end
