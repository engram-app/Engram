defmodule Engram.Notes.CrdtPersistence do
  @moduledoc """
  `Yex.Sync.SharedDoc.PersistenceBehaviour` impl, posture C.

  * `bind/3`  — on room start, decrypt the note's `crdt_state` snapshot and
    apply it, then replay the encrypted tail-log. The room's doc is then the
    authoritative merge of snapshot + all updates since.
  * `update_v1/4` — append each incoming update to the encrypted tail-log
    (cheap, frequent). The full snapshot is rewritten on debounced checkpoints
    (`Engram.Notes.CrdtCheckpoint`), NOT here — keeps the hot path O(append).
  * `unbind/3` — on graceful room exit (last observer disconnect with
    `auto_exit: true`), run a full synchronous checkpoint: materializes
    content/content_hash/seq into the notes row and enqueues a debounced
    embed. When text is unchanged the checkpoint degrades to a
    snapshot-compaction write with no version/seq churn.
  """
  @behaviour Yex.Sync.SharedDoc.PersistenceBehaviour

  # INVARIANT (load-bearing since tail reads became vault-scoped): the vault_id
  # threaded through this module's state MUST equal the vault_id on the note's
  # own row.
  #
  # `update_v1/4` stamps every tail row with the state's vault_id, and every
  # read filters on it, so the two are self-consistent. The risk is a room
  # started under the WRONG vault: before scoping, reads were vault-agnostic and
  # such a mismatch was harmless; now it silently truncates the note's history
  # to whatever that room wrote.
  #
  # Nothing enforces this at runtime — the room's vault comes from
  # `CrdtRegistry.ensure_started/4`, which the channel calls with the socket's
  # vault after `resolve_note_id/3` has already proven the note belongs to it.
  # `tail_rows/2` logs when a note has rows that are ALL foreign, which is the
  # observable symptom if that ever stops holding.

  import Ecto.Query
  alias Engram.{Accounts, Crypto, Repo}
  alias Engram.Logger.Metadata

  alias Engram.Notes.{
    CheckpointGate,
    CrdtBridge,
    CrdtCheckpointTimer,
    CrdtTransport,
    CrdtUpdateLog,
    Enqueue,
    Note
  }

  require Logger

  # `bind/3`'s return value becomes the `persistence_state` threaded to every
  # subsequent `update_v1/4` and `unbind/3` call. We resolve the user ONCE here
  # and cache it in the state so the per-update hot path does NOT do an
  # `Accounts.get_user!` DB round-trip on every keystroke.
  @impl true
  def bind(%{user_id: user_id, vault_id: vault_id, note_id: note_id} = state, _doc_name, doc) do
    # bind/3 runs INSIDE the room (SharedDoc.init). Trapping exits here makes
    # gen_server intercept the supervisor's :shutdown on deploys and run
    # terminate/2 → unbind → full checkpoint, instead of dying unflushed.
    # Guarded on :"$initial_call" (set by proc_lib for GenServers) so a direct
    # bind/3 call from a bare test process does not leak trap_exit=true into
    # the test, where it would swallow linked-process crashes.
    if Process.get(:"$initial_call") != nil, do: Process.flag(:trap_exit, true)

    # Cached (Engram.Cache, evicted on any users UPDATE, so a DEK rotation is
    # seen). A missing user must not get a room: raise, like get_user!/1 did.
    user = Accounts.get_user(user_id) || raise "CrdtPersistence.bind/3: user #{user_id} not found"

    {:ok, presence} =
      Repo.with_tenant(user_id, fn ->
        # NO lock here, deliberately (#1409). bind/3 runs INLINE inside the one
        # DynamicSupervisor process per node (start_child is a synchronous call
        # whose handle_call runs the child's init), so anything that blocks here
        # stalls EVERY other room start on this node. A detached genesis seed
        # racing this read is instead resolved by the seed itself: it commits,
        # then terminates whatever room appeared in its window
        # (`EngramWeb.CrdtChannel.evict_racing_room/1`), so the replacement room
        # binds against the committed row.
        #
        # This read is also the existence check (it replaced a separate
        # `Notes.note_in_vault?/3` transaction on the room-free path): a note
        # outside this user's vault, or deleted, gets no room. See below.
        case Repo.get(Note, note_id) do
          %Note{user_id: ^user_id, vault_id: ^vault_id, deleted_at: nil} = note ->
            # Hydrate the snapshot when present. Absent one, the doc stays
            # empty: nothing here re-seeds it from `notes.content` (see the
            # NOTE below). CrdtCheckpoint guards against that empty doc being
            # materialized back over the body.
            snapshot_echoes =
              case Crypto.decrypt_crdt_state(note, user) do
                {:ok, snapshot} when is_binary(snapshot) ->
                  if apply_echoing?(doc, snapshot), do: 1, else: 0

                # No snapshot yet (`crdt_state_ciphertext` is nil): legitimate for
                # a note that has never been checkpointed. The doc stays empty and
                # `replay_tail/3` below fills it from the log.
                {:ok, nil} ->
                  0

                # FAIL LOUD. This used to fall into the clause above via a
                # catch-all `_`, which is the opposite policy from
                # `Notes.maybe_merge_crdt/4` — that one refuses on the same signal
                # (`throw {:crdt_decrypt, err}`). bind/3 was the fail-OPEN sibling.
                #
                # Continuing here starts a FRESH lineage for a note that already
                # has state: the tail replays onto an empty doc, the room looks
                # converged, and the next checkpoint writes that truncated doc back
                # over the real content. A *transient* decrypt failure (DEK cache
                # miss, a read mid-DEK-rotation) would become permanent data loss.
                #
                # Raising fails the room start instead, so the client's join errors
                # and retries. A genuinely corrupt snapshot then surfaces as a loud,
                # repeated failure rather than as silent truncation.
                {:error, reason} ->
                  Logger.error(
                    "crdt bind refused: crdt_state decrypt failed for note #{note_id}",
                    Metadata.with_category(:error, :sync,
                      note_id: note_id,
                      reason: Metadata.safe_reason(reason)
                    )
                  )

                  raise "CrdtPersistence.bind/3: crdt_state decrypt failed for note #{note_id} (#{inspect(reason)}) — refusing to bind an empty doc over existing state"
              end

            {applied, tail_echoes} =
              replay_counting(doc, user, note_id, tail_rows(note_id, vault_id))

            # y_ex installs the doc's update monitor BEFORE bind/3 runs
            # (doc_server_worker.ex: monitor_update_v1, then module.init), so
            # every apply above posted an `{:update_v1, ...}` to this room's own
            # mailbox. Without a credit, update_v1/4 re-appended the loaded
            # state to the tail and fanned it out to every device on each room
            # start. Same fix as `CrdtIndexPersistence` (:index_replay_echoes):
            # those messages are the next update_v1 calls this process makes
            # (FIFO, sent before any client frame), so a count is exact.
            #
            # It counts CHANGES, not applies: an apply that changed nothing
            # posts nothing, and a leftover credit would swallow a real client
            # update's tail append. The normalize below is NOT credited: it
            # writes new ops, which must be appended.
            #
            # Only a room has the monitor: a direct bind/3 call (tests) posts
            # nothing, and a credit there would swallow its next update_v1.
            if in_room?() do
              Process.put(:crdt_replay_echoes, snapshot_echoes + tail_echoes)
              Process.put(:crdt_tail_ids, applied)
            end

            # NOTE: the server no longer seeds the doc from `notes.content`
            # here. That seed made the SERVER a third writer of note content,
            # and reconciling three representations (doc / notes.content / disk)
            # is the shape of every "which copy is authoritative" bug we have
            # shipped. Non-CRDT writes (REST / MCP / web) already merge their
            # plaintext INTO the persisted CRDT state at WRITE time, roomlessly
            # — `Notes.upsert_note` -> doc_from_state -> replay_tail ->
            # merge_plaintext_* — so a bound room already holds the body and
            # `notes.content` is a DERIVED projection maintained by the
            # checkpoint materializer.

            :ok = CrdtBridge.normalize_doc(doc)
            :present

          _absent ->
            :absent
        end
      end)

    if in_room?() do
      # Refuse the room rather than start one bound to ids that do not own the
      # note: rooms are keyed by note id alone, so it would be found by the
      # note's real owner and append their edits under the wrong tenant. A
      # `{:shutdown, _}` exit fails the start quietly (no crash report);
      # `CrdtRegistry.ensure_started/4` answers `{:error, :not_found}`.
      if presence == :absent, do: exit({:shutdown, :note_not_found})

      # Who this room is for. A caller that finds the room already running
      # checks it (`owned_by?/2`) instead of re-reading the note.
      Process.put(:crdt_owner, {user_id, vault_id})
    end

    # Cache the resolved user in the threaded state for update_v1/4 and unbind/3.
    Map.put(state, :user, user)
  end

  # Uses the user cached by bind/3 when present (the live room path); falls back
  # to a lazy fetch when called with a bare state map (direct unit-test calls).
  @impl true
  def update_v1(state, update, name, doc) do
    case Process.get(:crdt_replay_echoes, 0) do
      n when n > 0 ->
        # bind/3 loading persisted state, already durable: see bind/3.
        Process.put(:crdt_replay_echoes, n - 1)
        state

      _ ->
        append_update(state, update, name, doc)
    end
  end

  defp append_update(
         %{user_id: user_id, vault_id: vault_id, note_id: note_id} = state,
         update,
         _name,
         doc
       ) do
    user = state[:user] || Accounts.get_user!(user_id)
    interleave_hook(:before_tail_append)

    with :ok <- append_fault(),
         {:ok, {ct, nonce}} <- Crypto.encrypt_crdt_state(update, user, note_id) do
      row_id = UUIDv7.generate()

      {:ok, seq} =
        Repo.with_tenant(user_id, fn -> append_row(row_id, state, ct, nonce) end)

      # The id is now in the room's doc AND durably in the tail, so a
      # checkpoint of this room may prune it (see known_tail_ids/0). Only a
      # room: a direct call's `doc` is whatever the caller passed.
      if in_room?(), do: remember_tail_id(row_id)

      # Fan out the update to every device on this vault over the single
      # per-vault sync channel (the `document.updated` model). This is
      # what lets an IDLE note (one the client never STEP1-enrolled) converge
      # without opening its own CRDT room: the client applies these pushed
      # bytes straight to the note's Y.Doc. Fires on EVERY update source
      # (channel, REST /updates, deliver-out) because they all funnel here.
      # base64 because the JSON serializer can't carry raw binary; `head` lets
      # the client advance its per-note watermark without a REST round-trip.
      # Self-echo is harmless: the client applies with REMOTE_ORIGIN (no
      # re-broadcast) and Yjs re-apply is a no-op.
      #
      # NOTE — `b64` here is the DELTA (this single update), paired with the
      # FULL post-apply `head`. `CrdtDeliver.fanout_idle` sends FULL state under
      # the same contract. A device behind the delta's causal deps (it never
      # STEP1-enrolled and missed an earlier update) PENDS the delta in Yjs, so
      # it does NOT actually reach `head`. The client MUST NOT blind-trust `head`
      # in that case: `applyPushedNoteUpdate` checks `hasPendingGap` post-apply
      # and, on a gap, pulls the full delta from its real state vector and
      # advances the watermark only to the head it truly reached (plugin
      # `e2304ed`). Without that client guard, the cheap cold-reconcile hash gate
      # would skip a silently-partial note.
      # GUARANTEE BOUNDARY (review 2026-07-22): this seq does not advance per
      # socket delta (checkpoint owns it), so a same-note burst of live deltas
      # shares ONE seq — the plugin's behind-detector cannot see a loss WITHIN
      # such a burst; those heal via checkpoint/announce instead. Seq gap-heal
      # covers seq-BUMPING edits (REST/MCP/checkpoint-driven). And a nil seq
      # (row deleted concurrently, the Repo.get fallback) is no signal at all:
      # omit the key rather than ship "seq" => nil to the behind-detector.
      payload = %{
        "note_id" => note_id,
        "b64" => Base.encode64(update),
        "head" => CrdtTransport.head_marker(doc)
      }

      payload = if is_integer(seq), do: Map.put(payload, "seq", seq), else: payload

      Engram.Notes.FanoutPacer.emit(
        "sync:#{user_id}:#{vault_id}",
        "note_yjs_update",
        payload,
        note_id
      )
    else
      {:error, reason} ->
        # The update is in the doc but in no durable row. Every acknowledgement
        # (`CrdtTransport.confirm_appended/2`) is refused until a checkpoint of
        # this room commits the doc, so clients keep retrying; a retry is a
        # no-op apply and appends nothing, so clearing on the next confirm
        # would ack it while it is still only in memory. Check point now
        # rather than after the settle delay.
        Process.put(:crdt_append_failures, append_failures() + 1)

        case Process.get(:crdt_timer_pid) do
          pid when is_pid(pid) -> send(pid, :tick)
          _ -> :ok
        end

        Logger.error(
          "crdt_update_log encrypt failed note_id=#{note_id} reason=#{Metadata.safe_reason(reason)}",
          Metadata.with_category(:error, :sync, note_id: note_id)
        )
    end

    # Signal the checkpoint timer so it can debounce a snapshot flush.
    # update_v1 is called inside the room GenServer process; the timer pid
    # was stored there by CrdtDoc.start_link via Process.put(:crdt_timer_pid).
    case Process.get(:crdt_timer_pid) do
      pid when is_pid(pid) -> CrdtCheckpointTimer.notify_activity(pid)
      _ -> :ok
    end

    state
  end

  # ONE statement per keystroke (this is the hot path): the tail insert, the
  # crdt_head reset and the seq read for the fanout below.
  #
  # crdt_head: this update advanced the doc, so a stored head is stale. NULL it
  # in the same transaction (the BackfillCrdtHead worker re-warms it from
  # snapshot + full tail), guarded on not-NULL so an already-invalidated note
  # skips the write, and setting ONLY crdt_head (checkpoint owns
  # version/seq/updated_at).
  #
  # seq: the note's current vault-global change seq, carried on the fanout for
  # gap-heal (spec §3 Phase D2). Read by the outer SELECT, which sees the row as
  # of the statement start: the CTE changes only crdt_head, so that is the
  # current seq. Never a full Note load (crdt_state is KBs to MBs). An absent
  # row (deleted concurrently) reads as nil, which the fanout omits.
  #
  # A data-modifying CTE runs to completion whether or not the outer query
  # reads it.
  @append_sql """
  WITH appended AS (
    INSERT INTO crdt_update_log (id, note_id, user_id, vault_id, update_ciphertext, update_nonce)
    VALUES ($1, $2, $3, $4, $5, $6)
  ), head_reset AS (
    UPDATE notes SET crdt_head = NULL
    WHERE id = $2 AND kind = 'note' AND crdt_head IS NOT NULL
  )
  SELECT seq FROM notes WHERE id = $2
  """

  defp append_row(row_id, %{user_id: user_id, vault_id: vault_id, note_id: note_id}, ct, nonce) do
    params = [
      Ecto.UUID.dump!(row_id),
      Ecto.UUID.dump!(note_id),
      Ecto.UUID.dump!(user_id),
      Ecto.UUID.dump!(vault_id),
      ct,
      nonce
    ]

    case Repo.query!(@append_sql, params) do
      %{rows: [[seq]]} -> seq
      %{rows: []} -> nil
    end
  end

  # The tail row ids this room's doc holds: the rows bind/3 replayed and the
  # rows this room appended. In the room's process dictionary, because the
  # checkpoint timer reads them from inside the room (`SharedDoc.update_doc`),
  # where the persistence state is out of reach. Never a row that failed to
  # decrypt or a row another writer appended: those stay in the tail.
  defp remember_tail_id(id), do: Process.put(:crdt_tail_ids, [id | known_tail_ids()])

  @doc false
  # Whether this room was bound for `user_id`'s note in `vault_id`. Runs in the
  # room.
  @spec owned_by?(String.t(), String.t()) :: boolean()
  def owned_by?(user_id, vault_id), do: Process.get(:crdt_owner) == {user_id, vault_id}

  @doc false
  @spec known_tail_ids() :: [Ecto.UUID.t()]
  def known_tail_ids, do: Process.get(:crdt_tail_ids, [])

  @doc false
  # A checkpoint pruned these: stop offering them. Runs in the room.
  @spec forget_tail_ids([Ecto.UUID.t()]) :: :ok
  def forget_tail_ids(ids) do
    Process.put(:crdt_tail_ids, known_tail_ids() -- ids)
    :ok
  end

  @doc false
  # Appends that failed since the last committed checkpoint of this room. Runs
  # in the room (see `CrdtTransport.confirm_appended/2`).
  @spec append_failures() :: non_neg_integer()
  def append_failures, do: Process.get(:crdt_append_failures, 0)

  @doc false
  # A checkpoint of a snapshot taken when `append_failures/0` was `seen`
  # committed: those failed updates are durable now, and its pruned rows are
  # gone. A failure after the snapshot keeps the count. Runs in the room.
  @spec checkpointed([Ecto.UUID.t()], non_neg_integer()) :: :ok
  def checkpointed(pruned, seen) do
    if append_failures() == seen, do: Process.put(:crdt_append_failures, 0)
    forget_tail_ids(pruned)
  end

  # Test-only fault seam: nil outside tests.
  defp append_fault do
    case Application.get_env(:engram, :crdt_tail_append_fault) do
      nil -> :ok
      fun when is_function(fun, 0) -> fun.()
    end
  end

  # Runs on graceful room terminate (SharedDoc `auto_exit: true`). Materializes
  # content/content_hash/seq into the notes row and enqueues a debounced embed.
  # When text is unchanged, checkpoint degrades to a snapshot-compaction write
  # with no version/seq churn (the content_hash no-op guard).
  #
  # Concurrency-bounded (2026-07-09 pool-exhaustion fix): a socket drop with
  # `auto_exit: true` terminates ALL of that client's rooms at once, so up to
  # N synchronous checkpoints would fight the 10-connection pool and time out
  # (`DBConnection.ConnectionError`). CheckpointGate caps inline checkpoints;
  # under the cap we checkpoint synchronously as before (preserving
  # materialization timing for the common single-note-close case), and beyond
  # it we overflow to the durable, bounded `crdt_checkpoint` Oban queue so the
  # storm drains without exhausting the pool. Loss-free either way: the tail-WAL
  # is pruned only on a successful checkpoint. Any raise inside checkpoint is
  # caught and logged there, so unbind always returns :ok.
  @impl true
  def unbind(%{user_id: user_id, vault_id: vault_id, note_id: note_id}, _doc_name, doc) do
    _ =
      if CheckpointGate.acquire() do
        try do
          # Prunes exactly the rows this doc holds (known_tail_ids/0). Rows
          # it never folded (another writer's, or undecryptable at bind) stay.
          Engram.Notes.CrdtCheckpoint.checkpoint(user_id, vault_id, note_id, doc,
            prune_ids: known_tail_ids()
          )
        after
          CheckpointGate.release()
        end
      else
        Enqueue.enqueue(
          Engram.Workers.CheckpointNote.new(%{
            user_id: user_id,
            vault_id: vault_id,
            note_id: note_id
          }),
          "crdt_checkpoint"
        )
      end

    :ok
  end

  # Replays the encrypted tail-log onto `doc` and returns the ids of the rows
  # that were ACTUALLY applied (decrypted successfully), in insertion order. A
  # caller that persists `doc` can then prune EXACTLY those rows — never a row
  # it did not fold in (a later concurrent append) and never a row that failed
  # to decrypt (which stays in the log for a future successful replay). `[]`
  # means nothing applied, which bind/3 reads as "fresh room".
  #
  # Returning applied ids (not a count) is the #285 fix substrate: an
  # `inserted_at`/id RANGE watermark can tie or reorder within a clock tick and
  # prune an unfolded row; an exact-id prune cannot.
  #
  # Public so `maybe_merge_crdt/4` in `Engram.Notes` can reuse this function
  # when building the REST merge base: snapshot + tail ≡ bind/3's recipe.
  # Must be called inside the caller's `Repo.with_tenant` transaction — it
  # queries `CrdtUpdateLog` which is tenant-scoped by RLS.
  @doc false
  @spec replay_tail(Yex.Doc.t(), map(), String.t(), String.t()) :: [Ecto.UUID.t()]
  def replay_tail(doc, user, note_id, vault_id) do
    apply_tail_rows(doc, user, note_id, tail_rows(note_id, vault_id))
  end

  @doc """
  A note's tail rows, oldest first. The caller supplies the tenant (this issues
  a bare `Repo.all`, like the rest of this module's reads).

  Split out so a caller can find out whether there is anything to fold BEFORE
  paying to materialize a doc to fold it into. Most notes in a bulk import have
  an empty tail, and for those the fold is pure overhead.
  """
  @spec tail_rows(String.t(), String.t()) :: [struct()]
  def tail_rows(note_id, vault_id) do
    # Read by note only and split by vault in memory: the foreign-vault check
    # below then costs no second query. Foreign rows only exist in the #1318
    # corruption shape, so the extra rows fetched are almost always none.
    {rows, foreign} =
      CrdtUpdateLog
      |> where([l], l.note_id == ^note_id)
      |> order_by([l], asc: l.inserted_at)
      |> Repo.all()
      |> Enum.split_with(&(&1.vault_id == vault_id))

    warn_on_foreign_vault_rows(note_id, vault_id, rows, length(foreign))
    rows
  end

  # Vault-scoping made a corrupt state SILENT. Before it, a row stamped with the
  # wrong vault was folded (wrong content, but visible) and pruned by the
  # watermark. Now it is invisible to BOTH the fold and the prune: it can never
  # be read and can never be deleted, so it accumulates forever with no symptom.
  # That is better for correctness and worse for diagnosis, which is only an
  # acceptable trade if the state is detectable — hence this.
  #
  # Only warns when the scoped rows are EMPTY, i.e. the case where an invisible
  # row would otherwise be indistinguishable from "no tail at all". A note with
  # rows is already proving the filter matches.
  defp warn_on_foreign_vault_rows(_note_id, _vault_id, [_ | _], _hidden), do: :ok
  defp warn_on_foreign_vault_rows(_note_id, _vault_id, [], 0), do: :ok

  defp warn_on_foreign_vault_rows(note_id, vault_id, [], hidden) do
    Logger.warning(
      "crdt tail rows exist for this note but ALL belong to another vault — " <>
        "they can neither be folded nor pruned (#1318 corruption shape): " <>
        "note_id=#{note_id} vault_id=#{vault_id} hidden_rows=#{hidden}",
      Metadata.with_category(:warning, :sync, note_id: note_id)
    )
  end

  @doc """
  Applies already-fetched tail rows to `doc`, returning the ids that decrypted.

  Split out of `replay_tail/3` so a BATCH caller can fetch one page's tail in a
  single query and replay from those buffers. That is not just an N+1 fix: it
  removes a race. Fetching rows and replaying them in separate statements at
  READ COMMITTED lets a checkpoint prune the tail in between, so the replay
  comes up empty against a snapshot that predates the fold. Yjs updates are
  idempotent and commutative, so replaying a buffer a checkpoint has since
  folded in is harmless — holding the rows is strictly safer than re-reading
  them.
  """
  @spec apply_tail_rows(Yex.Doc.t(), map(), String.t(), [struct()]) :: [Ecto.UUID.t()]
  def apply_tail_rows(doc, user, note_id, rows) do
    {applied, _echoes} = replay_counting(doc, user, note_id, rows)
    applied
  end

  # Test-only seam (`Engram.CheckpointInterleave`): nil outside those tests.
  defp interleave_hook(point) do
    case Application.get_env(:engram, :checkpoint_interleave_hook) do
      nil -> :ok
      fun when is_function(fun, 1) -> _ = fun.(point)
    end

    :ok
  end

  defp in_room?, do: match?({Yex.DocServer.Worker, _, _}, Process.get(:"$initial_call"))

  # Whether applying `update` changed `doc`, i.e. whether it posted an
  # `{:update_v1, ...}`. The state vector advances iff new items integrated. A
  # delete-only update can emit without advancing it: that under-counts, which
  # only re-appends an idempotent row. Over-counting would drop a real update.
  defp apply_echoing?(doc, update) do
    before = Yex.encode_state_vector(doc)
    _ = Yex.apply_update(doc, update)
    Yex.encode_state_vector(doc) != before
  end

  # apply_tail_rows/4 plus how many of the applies changed the doc.
  defp replay_counting(doc, user, note_id, rows) do
    rows
    |> Enum.reduce({[], 0}, fn row, {applied, echoes} ->
      shaped = %Note{
        id: note_id,
        dek_version: Crypto.row_version_aad_bound(),
        crdt_state_ciphertext: row.update_ciphertext,
        crdt_state_nonce: row.update_nonce
      }

      case Crypto.decrypt_crdt_state(shaped, user) do
        {:ok, upd} when is_binary(upd) ->
          {[row.id | applied], echoes + if(apply_echoing?(doc, upd), do: 1, else: 0)}

        {:error, reason} ->
          Logger.warning(
            "crdt replay_tail decrypt failed note_id=#{note_id} reason=#{Metadata.safe_reason(reason)}",
            Metadata.with_category(:warning, :sync,
              note_id: note_id,
              reason: Metadata.safe_reason(reason)
            )
          )

          {applied, echoes}

        unexpected ->
          Logger.warning(
            "crdt replay_tail unexpected decrypt result note_id=#{note_id} result=#{Metadata.safe_reason(unexpected)}",
            Metadata.with_category(:warning, :sync,
              note_id: note_id,
              reason: "unexpected_shape"
            )
          )

          {applied, echoes}
      end
    end)
    |> then(fn {applied, echoes} -> {Enum.reverse(applied), echoes} end)
  end
end
