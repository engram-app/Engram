defmodule Engram.Notes.CrdtIndexDoc do
  @moduledoc """
  Per-VAULT index document room (#1150), the substrate for making note identity
  a CRDT instead of a REST projection (engram-app/engram-workspace#167).

  Identity today lives in three places that must agree: `NoteIdMap` in the
  client, the REST manifest, and the seq cursor. `relay-pattern-audit.md` (engram-workspace repo)
  traces every drift incident to that split. Relay has no such class because
  identity converges through the SAME channel as content — a `Y.Map` inside a
  synced doc. This room is that map.

  Doc shape: one `Y.Map` named `filemeta_v0`, `path -> %{note_id, type, hash}`.
  One room per vault rather than per note, so this *improves* the `:global`
  registration concern in #896 rather than worsening it.

  ## Who writes it, and who reads it

  This map is AUTHORITATIVE for note paths as of #1151 step 2 — see
  `docs/context/crdt-identity-authority.md`.

  * `Engram.Notes.Identity` is the ONLY server-side writer. Every server-side
    rename, delete, folder rename and batch move claims through it, and the
    claim is the commit.
  * `Engram.Workers.ProjectVaultIndex` reads it back and derives the
    `notes.path_*` columns from it. It must never claim — `rename_note/5` takes
    `index: :skip` for exactly that caller, because deriving rows FROM the map
    and then writing to it is a feedback loop.

  No CLIENT writes it yet; that is Engram-obsidian#362, with #363 handing
  identity over outright. So in production the map is still empty and
  projection is a no-op — which is a statement about the client we ship, not
  about what the server accepts.

  ## The idle drain (#1152)

  Draining a room is lossless only if something checkpoints it on the way out.
  #1151 gave this room that (`CrdtIndexPersistence.unbind/3`), and #1391 gave it
  a tail log so an ungraceful death is survivable too. Both were prerequisites;
  neither wired anything up.

  It is wired now. `start_link/1` starts a `CrdtCheckpointTimer` in `mode:
  :index`, which is the timer generalised off `note_id` — it keys on `vault_id`
  and, crucially, **never checkpoints on a tick**. Only the room's own
  persistence state knows which tail rows failed to replay, so a checkpoint that
  did not come from `unbind/3` would prune rows it never folded in. The drain is
  the mechanism instead: observers let go, `auto_exit` fires on the last one,
  and `terminate/2` checkpoints with the state that has the answer.

  This matters more here than for a note room. `auto_exit` bounds a note room
  well, because a note is observed only while it is open. This room is observed
  for as long as ANY socket on the vault is connected, so without the drain its
  residency is session-length and tracks concurrent connections rather than
  mutation rate.

  **On by default, and not behind a flag.** Note rooms take the drain as an
  opt-in because `auto_exit` already bounds them; this room does not have that
  luxury, so shipping it off would ship the measured 7.91 MB/vault residency and
  call it done. `@default_idle_exit_ms` is the value, overridable per room for
  tests. There is no "drain disabled" mode here to fall back to — the way back
  is a different number, not a switch.
  """

  alias Engram.Notes.CrdtCheckpointTimer

  @map_name "filemeta_v0"

  # The drain is ON for this room, unconditionally — not a flag, not opt-in.
  #
  # Unlike a note room, which `auto_exit` bounds well because a note is observed
  # only while it is open, this room is observed for as long as ANY socket on
  # the vault is connected. Without a drain its residency is session-length,
  # which #1149 measured at 7.91 MB per 10k-note vault. Shipping that OFF by
  # default would mean shipping the measured problem and calling it done.
  #
  # Draining is lossless and cheap to undo: `terminate/2` checkpoints, the tail
  # log covers an ungraceful death, and the next index frame re-spins the room
  # through `ensure_index_room/1`. The cost of a wrong value is a re-bind
  # (decrypt + replay), not a lost claim.
  #
  # 5 minutes of no index WRITES — renames, creates, deletes. A client that is
  # merely connected and reading generates no activity here, which is the point:
  # residency should track mutation, not connection count.
  @default_idle_exit_ms 300_000

  @doc """
  The `Y.Map` name holding `path -> %{note_id, type, hash}`.

  Matches Relay's `filemeta_v0` (`SyncStore.ts:20`) on purpose: the shape is
  the part of Relay's design that removes the drift class, and keeping the name
  makes the correspondence checkable rather than folkloric.
  """
  @spec map_name() :: String.t()
  def map_name, do: @map_name

  @doc """
  Start the index room for `vault_id`, registered `{:global, {:crdt_index, id}}`.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()} | :ignore
  def start_link(opts) do
    vault_id = Keyword.fetch!(opts, :vault_id)
    user_id = Keyword.fetch!(opts, :user_id)

    result =
      Yex.Sync.SharedDoc.start_link(
        [
          doc_name: vault_id,
          # Must match CrdtBridge.new_doc/0 — UTF-16 offsets are wire-compatible
          # with Yjs JS clients; the y_ex default (:bytes) is NOT.
          doc_option: %Yex.Doc.Options{offset_kind: :utf16},
          persistence:
            {Engram.Notes.CrdtIndexPersistence, %{user_id: user_id, vault_id: vault_id}},
          auto_exit: true
        ],
        name: Engram.Notes.CrdtIndexRegistry.global_name(vault_id)
      )

    with {:ok, room_pid} <- result do
      # #1152's remaining half. `auto_exit` alone bounds a NOTE room, which is
      # observed only while the note is open — but this room is observed for as
      # long as any socket on the vault is connected, so its lifetime is
      # session-length and its residency tracks concurrent connections rather
      # than mutation rate.
      #
      # `mode: :index` because the timer is otherwise note-keyed and would
      # checkpoint on every tick. This room must NOT: only its own persistence
      # state knows which tail rows failed to replay, so the checkpoint has to
      # come from `unbind/3`. The drain is what gets it there — observers let
      # go, auto_exit fires, terminate checkpoints.
      {:ok, timer_pid} =
        CrdtCheckpointTimer.start_link(
          room_pid: room_pid,
          user_id: user_id,
          vault_id: vault_id,
          mode: :index,
          # Explicit and never nil. The timer treats nil as "drain disabled",
          # so falling through to its config fallback would have made this
          # room's residency depend on a note-room knob being set.
          idle_exit_ms: Keyword.get(opts, :idle_exit_ms, @default_idle_exit_ms)
        )

      # Same channel as the note room: update_v1 runs INSIDE this process, so
      # it reads the timer pid straight out of the process dictionary rather
      # than doing a registry lookup on every update.
      Yex.Sync.SharedDoc.update_doc(room_pid, fn _doc ->
        Process.put(:crdt_timer_pid, timer_pid)
      end)

      result
    end
  end

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :vault_id)},
      start: {__MODULE__, :start_link, [opts]},
      # :temporary for the same reason note rooms are — a restarted room would
      # have zero observers and (auto_exit being :DOWN-driven) never exit, i.e.
      # an immortal orphan. Channels re-establish it on demand.
      restart: :temporary,
      # LONGER than a note room's 15 s, not shorter, and the OTP default of
      # 5_000 is badly wrong here.
      #
      # This room now HAS a tail log (#1391), so a blown deadline no longer
      # loses every index write since the last exit — the next bind replays the
      # tail, exactly as a note room replays its own. What a blown deadline
      # still costs is the FOLD: the checkpoint never runs, so nothing is
      # pruned and the tail keeps growing across restarts. The generous
      # deadline is now about bounding tail growth and wasted replay work, not
      # about preventing permanent loss.
      #
      # And the deadline is harder to hit: unbind/3 does a user lookup, a full
      # doc encode, AES-GCM over a blob #1149 sizes at ~2.0 MB for a 10k-note
      # vault, and an insert_all — during a deploy stampede where every room
      # terminates at once and contends for the DB pool (#851).
      shutdown: 30_000
    }
  end
end
