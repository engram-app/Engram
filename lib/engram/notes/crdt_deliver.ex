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
       apply the merged plaintext onto the room's owned `Y.Text` via
       `SharedDoc.update_doc/2`. The room's `handle_update_v1` then broadcasts
       the resulting v1 frame to every observer (and appends it to the durable
       update-log). Routing through the owner process keeps the single-owner
       invariant — the doc is never mutated from two processes.

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

  alias Engram.Notes.{CrdtBridge, CrdtRegistry}
  alias Yex.Sync.SharedDoc

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
      push_to_live_room(note_id, content)
      announce(user_id, vault_id, path)
    end

    :ok
  end

  # Step 1 — push the diff frame to a live room's observers, if one exists.
  # Non-creating lookup so an external write never spins a room for a note
  # nobody is observing. `:global.whereis_name` can hand back a room that is
  # mid auto-exit, so guard the GenServer.call against an :exit — the announce
  # (step 2) still lets clients re-pull when the push could not land.
  defp push_to_live_room(note_id, content) do
    case CrdtRegistry.lookup(note_id) do
      nil ->
        :ok

      room ->
        try do
          SharedDoc.update_doc(room, fn doc ->
            CrdtBridge.ingest_plaintext(doc, content)
          end)
        catch
          :exit, _reason -> :ok
        end
    end
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
