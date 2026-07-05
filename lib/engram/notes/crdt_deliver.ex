defmodule Engram.Notes.CrdtDeliver do
  @moduledoc """
  Deliver-out bridge: propagate non-CRDT-origin content writes (REST / MCP /
  web SPA / folder cascade) to connected CRDT clients.

  The write path (`Notes.upsert_note/4`) merges incoming plaintext into the
  note's persisted Yjs state, but a write that does NOT arrive over the `crdt:`
  channel never reaches the live in-memory room nor any client observing it.
  This module closes that gap (spec §4.3 deliver-out / handoff gap ③) with two
  complementary, best-effort, post-commit steps:

    1. If a room is already live for the note (an Obsidian client has it open),
       apply the note's just-committed merged CRDT state onto the room's owned
       doc via `SharedDoc.update_doc/2`. Applying the STORED STATE (not a
       plaintext re-diff) keeps the room on the same Yjs lineage as the
       snapshot: the write path already encoded this change once
       (`maybe_merge_crdt`), and re-encoding it here with the room's own
       client-id would create a second, concurrent encoding of the same edit.
       The next REST merge then replays that room-lineage encoding from the
       update-log tail onto a snapshot that already carries the merge-lineage
       encoding — Yjs unions both and the text doubles ("Iteration 2" →
       "Iteration 22" → the e2e "Iteration 67" interleave). The room's
       `handle_update_v1` broadcasts the resulting v1 frame to every observer
       (and appends it to the durable update-log — now a subset of the stored
       snapshot, so tail replay is idempotent). Routing through the owner
       process keeps the single-owner invariant.

    2. ALWAYS announce `crdt_doc_ready` on the vault topic so any client that
       does not yet hold a room for this note (including a brand-new note just
       created via REST/MCP) opens one and pulls via sync step-1. Step 1 alone
       is insufficient: the plugin's enrollment is once-per-session, so an
       already-enrolled client only converges from a pushed frame, while a
       not-yet-enrolled client only converges from the announce.

  Called unconditionally from the write path (CRDT is the only content-sync
  path); this module always delivers when invoked. It never raises — a delivery
  failure must not fail the write.
  """

  alias Engram.{Accounts, Crypto, Repo}
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtBridge, CrdtRegistry, Note}
  alias Yex.Sync.SharedDoc

  require Logger

  @doc """
  Propagate a committed plaintext write for `note_id` to CRDT clients on
  `vault_id`. `content` is the post-merge plaintext (the note's materialized
  body); `path` is the note's vault-relative path. Returns `:ok` regardless of
  per-step outcome.
  """
  @spec deliver_out(String.t(), String.t(), String.t(), String.t(), String.t()) :: :ok
  def deliver_out(user_id, vault_id, path, note_id, content)
      when is_binary(content) do
    # CRDT manages MARKDOWN content only — the plugin's routeModify enrolls only
    # `.md` into Yjs (mirroring Relay's SyncType.Document = "markdown"; canvas and
    # other types are separate, non-markdown-Yjs sync paths). Announcing CRDT for
    # a non-markdown note (e.g. `.canvas`) makes the client enroll it into a Yjs
    # doc, flush it to disk (marking the path recently-flushed), and then SUPPRESS
    # the user's next real edit as an echo — silently dropping the write. Those
    # files sync via the legacy push path, so only deliver/announce for `.md`.
    if String.ends_with?(path, ".md") do
      push_to_live_room(user_id, note_id, content)
      announce(user_id, vault_id, path)
    end

    :ok
  end

  # Step 1 — converge a live room onto the just-committed state, if one exists.
  # Non-creating lookup so an external write never spins a room for a note
  # nobody is observing.
  #
  # Applies the stored merged state (shared lineage — see moduledoc). The
  # plaintext re-diff runs ONLY for rows that have no CRDT state at all
  # (legacy/lazy rows) — there is no competing lineage to double. A note whose
  # state exists but fails to load (decrypt error, KMS outage, missing row)
  # SKIPS the push instead: re-encoding its content on the room's lineage is
  # the doubling corruption this module exists to prevent, and the announce
  # (step 2) still fires so enrolled clients re-pull. Every skip is logged at
  # :error (Sentry-visible) — a sustained fallback rate must be loud.
  defp push_to_live_room(user_id, note_id, content) do
    case CrdtRegistry.lookup(note_id) do
      nil ->
        :ok

      room ->
        case load_merged_state(user_id, note_id) do
          {:ok, state} when is_binary(state) ->
            room_apply(room, note_id, fn doc -> apply_state(doc, state, note_id) end)

          {:ok, nil} when content == "" ->
            # Empty content on a room with NO persisted CRDT state is ambiguous:
            # either a genuinely empty note (ingesting "" is a no-op anyway) or a
            # caller that reached deliver-out with UNLOADED content. The
            # folder-rename cascade is the latter: it scans meta columns only, so
            # `note.content` is nil -> "". Ingesting "" would diff the live doc's
            # body down to empty and clear its frontmatter — a silent wipe of an
            # open, unedited note. Skip the plaintext push; the announce (step 2)
            # still fires so enrolled clients re-pull. A real clear-to-empty
            # arrives as a CRDT edit, never through this deliver-out fallback.
            :ok

          {:ok, nil} ->
            room_apply(room, note_id, fn doc -> CrdtBridge.ingest_plaintext(doc, content) end)

          {:error, _reason} ->
            # Already logged in load_merged_state. Deliberately no ingest.
            :ok
        end
    end
  end

  # `:global.whereis_name` can hand back a room that is mid auto-exit, so the
  # GenServer.call is guarded against benign exits (the announce still lets
  # clients re-pull when the push could not land). Every OTHER exit reason —
  # call timeout, a crash of the room while running our fun — is a real bug
  # signal and is logged at :error rather than swallowed: with
  # `restart: :temporary` a crashed room drops all observers, and a repeating
  # crash loop would otherwise produce zero log lines from this module.
  defp room_apply(room, note_id, fun) do
    SharedDoc.update_doc(room, fun)
  catch
    :exit, {:noproc, _} ->
      :ok

    :exit, {:normal, _} ->
      :ok

    :exit, {:shutdown, _} ->
      :ok

    :exit, reason ->
      Logger.error(
        "crdt deliver room push exited",
        Metadata.with_category(:error, :sync, note_id: note_id, reason: inspect(reason))
      )

      :ok
  end

  defp apply_state(doc, state, note_id) do
    case Yex.apply_update(doc, state) do
      :ok ->
        :ok

      {:error, reason} ->
        # The just-committed state failed to apply — the doc or the state is
        # already suspect, so plaintext-diffing into that same doc would be
        # the worst possible response (foreign-lineage re-encode on top of a
        # broken doc). Skip; observers converge via the announce → step-1
        # re-pull against a fresh room.
        Logger.error(
          "crdt deliver apply_update failed — skipping push",
          Metadata.with_category(:error, :sync, note_id: note_id, reason: inspect(reason))
        )

        :ok
    end
  end

  # Loads + decrypts the note's committed CRDT snapshot. Runs post-commit in
  # the writer process, so the row read here is the state the write just
  # persisted. Returns:
  #   {:ok, binary} — the merged state to apply (shared lineage)
  #   {:ok, nil}    — the row has NO CRDT state (legacy/lazy row); plaintext
  #                   ingest is the only delivery available and is safe
  #   {:error, r}   — the state exists but could not be read (decrypt/KMS/
  #                   missing row/raise) — logged here at :error; the caller
  #                   must NOT fall back to a plaintext re-encode
  # Never raises/exits/throws (delivery must not fail the write).
  defp load_merged_state(user_id, note_id) do
    user = Accounts.get_user!(user_id)

    result =
      Repo.with_tenant(user_id, fn ->
        case Repo.get(Note, note_id) do
          nil ->
            {:error, :missing_row}

          %Note{crdt_state_ciphertext: nil} ->
            {:ok, nil}

          %Note{} = note ->
            case Crypto.decrypt_crdt_state(note, user) do
              {:ok, state} when is_binary(state) -> {:ok, state}
              {:ok, nil} -> {:ok, nil}
              {:error, reason} -> {:error, reason}
            end
        end
      end)

    # with_tenant wraps the fun's return in {:ok, _} (Ecto transaction).
    case result do
      {:ok, {:ok, state_or_nil}} ->
        {:ok, state_or_nil}

      {:ok, {:error, reason}} ->
        log_state_load_failure(note_id, reason)
        {:error, reason}

      {:error, reason} ->
        log_state_load_failure(note_id, {:tenant_txn, reason})
        {:error, reason}
    end
  rescue
    err ->
      log_state_load_failure(note_id, Exception.format(:error, err, __STACKTRACE__))
      {:error, :raised}
  catch
    kind, reason ->
      log_state_load_failure(note_id, {kind, reason})
      {:error, :caught}
  end

  defp log_state_load_failure(note_id, reason) do
    Logger.error(
      "crdt deliver state load failed — skipping room push (announce still fires)",
      Metadata.with_category(:error, :sync, note_id: note_id, reason: inspect(reason))
    )
  end

  # Step 2 — discovery announce. Mirrors the channel's own `crdt_doc_ready`
  # event (CrdtChannel.ensure_room/2); the plugin handles both identically.
  defp announce(user_id, vault_id, path) do
    _ =
      EngramWeb.Endpoint.broadcast(
        "crdt:#{user_id}:#{vault_id}",
        "crdt_doc_ready",
        %{"doc_id" => "#{vault_id}/#{path}"}
      )

    :ok
  end
end
