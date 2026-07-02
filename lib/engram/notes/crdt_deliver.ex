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
  # nobody is observing. `:global.whereis_name` can hand back a room that is
  # mid auto-exit, so guard the GenServer.call against an :exit — the announce
  # (step 2) still lets clients re-pull when the push could not land.
  #
  # Applies the stored merged state (shared lineage — see moduledoc). Falls
  # back to the legacy plaintext re-diff only when the state cannot be loaded
  # (no note row / decrypt failure) so delivery still happens; that path
  # re-encodes the change on the room's lineage and is NOT double-safe, but a
  # rare degraded delivery beats none.
  defp push_to_live_room(user_id, note_id, content) do
    case CrdtRegistry.lookup(note_id) do
      nil ->
        :ok

      room ->
        state = load_merged_state(user_id, note_id)

        try do
          SharedDoc.update_doc(room, fn doc ->
            apply_or_ingest(doc, state, content, note_id)
          end)
        catch
          :exit, _reason -> :ok
        end
    end
  end

  defp apply_or_ingest(doc, state, content, note_id) when is_binary(state) do
    case Yex.apply_update(doc, state) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "crdt deliver apply_update failed, falling back to plaintext ingest",
          Metadata.with_category(:warning, :sync, note_id: note_id, reason: inspect(reason))
        )

        CrdtBridge.ingest_plaintext(doc, content)
    end
  end

  defp apply_or_ingest(doc, nil, content, _note_id) do
    CrdtBridge.ingest_plaintext(doc, content)
  end

  # Loads + decrypts the note's committed CRDT snapshot. Runs post-commit in
  # the writer process, so the row read here is the state the write just
  # persisted. Returns nil on any failure — the caller degrades to the
  # plaintext-ingest fallback. Never raises.
  defp load_merged_state(user_id, note_id) do
    user = Accounts.get_user!(user_id)

    result =
      Repo.with_tenant(user_id, fn ->
        with %Note{} = note <- Repo.get(Note, note_id),
             {:ok, state} when is_binary(state) <- Crypto.decrypt_crdt_state(note, user) do
          state
        else
          _ -> nil
        end
      end)

    # with_tenant wraps the fun's return in {:ok, _} (Ecto transaction).
    case result do
      {:ok, state} when is_binary(state) -> state
      _ -> nil
    end
  rescue
    err ->
      Logger.warning(
        "crdt deliver state load failed",
        Metadata.with_category(:warning, :sync,
          note_id: note_id,
          reason: Exception.format(:error, err, __STACKTRACE__)
        )
      )

      nil
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
