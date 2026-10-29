defmodule Engram.Notes.CrdtIndexPersistence do
  @moduledoc """
  `Yex.Sync.SharedDoc.PersistenceBehaviour` for the per-vault index room
  (#1150 built the room; #1151 makes it durable).

  * `bind/3` — decrypt the vault's `filemeta_v0` snapshot and apply it, so a
    re-spun room comes back with the index it had.
  * `unbind/3` — on graceful exit (last observer leaves, `auto_exit: true`),
    encrypt the whole doc state and upsert the single `vault_index_states` row.
  * `update_v1/4` — the tail append (#1391). See below.

  ## Why a tail log, when the writes are rare

  `CrdtPersistence` appends every update to `crdt_update_log` because a note
  room's hot path is keystrokes and losing a checkpoint interval means losing
  typing. The index's writes are rename/create/delete — orders of magnitude
  rarer — which is why this room shipped snapshot-only in #1150. Rarity turned
  out to be the wrong axis: what matters is what a lost write COSTS, not how
  often one happens.

  **That is why `update_v1/4` exists here (#1391).** The snapshot alone was
  written only when a room exited, so anything since the last checkpoint died
  with the process — and once #1151 step 2 made the map authoritative for paths,
  that meant losing committed path CLAIMS, after which projection drags the rows
  back to the superseded snapshot. Every update is now appended to
  `vault_index_update_log`, replayed on `bind/3` after the snapshot, and pruned
  by EXACT id when a checkpoint folds it in.

  Two consequences worth knowing:

  * A claim is durable once the ROOM has processed its own update message, not
    at the instant `update_doc/2` returns — `handle_update_v1` is delivered
    asynchronously. A kill inside that window still loses the update, exactly as
    it does for note rooms.
  * The prune is by exact id and never by a timestamp range. An update appended
    between the encode and the delete is not in the snapshot, and a range prune
    would silently drop the one claim the tail exists to protect.

  There is still no rebuild path in `lib/` — do not read "rebuildable" as "a
  rebuild exists".

  ## What bounds the tail (#2306)

  Every fold is `checkpoint/5`, run from inside the room process, because only
  the room's persistence state knows which rows failed to replay
  (`:folded_ids`); a checkpoint from anywhere else would prune rows it never
  folded in. It runs at three points:

  * `unbind/3`, on a graceful exit (#1152's idle drain makes that happen on a
    timer; `CrdtIndexDoc` wires it).
  * `update_v1/4`, once the appends since the last fold pass `fold_tail_rows`
    or `fold_tail_bytes`.
  * `bind/3`, right after a replay that itself passed those limits.

  Until #2306 only the first existed. A bulk first sync appends one claim per
  note, an OOM kill skips `unbind/3`, and every rebind replayed the same
  ever-growing tail on whichever node held the `:global` name: prod web tasks
  crash-looped for 22 min on 2026-10-29
  (`docs/context/web-oom-index-room-tail-replay-2026-10-29.md`). The bind fold
  means a crash after one good bind cannot replay that tail again.

  The replay itself reads `replay_page_rows` rows per statement, each window in
  its own short tenant transaction, and applies each page in ONE doc
  transaction. Its echoes are one message per page, but they sit in the room's
  mailbox until `bind/3` returns, so a large legacy tail still costs about its
  plaintext size there (far below the per-row state-vector garbage it replaced).

  The live and post-bind folds encode in the room and do the DB work in the
  room's one folder process (`fold_async/2`), one fold at a time with later
  requests coalesced; only `unbind/3` folds synchronously and only it enqueues
  projection. Every fold takes the per-vault lock, unions the stored snapshot
  with its encode in a fresh doc (so garbage collection compacts it), and
  prunes only the rows its own room holds, none after a skipped row.
  The limits live in `limit/1` and are overridable with
  `config :engram, Engram.Notes.CrdtIndexPersistence, ...`.

  Still unbounded: every fold during a DEK rotation is gated (it skips the
  prune too), so a long rotation lets the tail grow until the next fold after
  it.
  """
  @behaviour Yex.Sync.SharedDoc.PersistenceBehaviour

  import Ecto.Query, only: [where: 3, order_by: 3]

  alias Engram.Accounts
  alias Engram.Backfill.IdWindows
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtCheckpointTimer, Enqueue, VaultIndexState, VaultIndexUpdateLog}
  alias Engram.Repo

  require Logger

  # A 10k-note index encodes to ~2.0 MB (#1149). This is a blast-radius bound,
  # not a size target: the wire takes 5 MB frames at the edit-lane rate and the
  # room has no LRU or drain, so without a ceiling a client can grow an
  # arbitrarily large PERMANENT bytea. Refusing to persist keeps the last good
  # snapshot and leaves the room working in memory, which is the safer failure.
  @max_snapshot_bytes 16_000_000

  # There is no metric on the note checkpoint path either, which is why a
  # checkpoint silently ceasing to work is only visible as the absence of log
  # lines nobody queries. This one is the ONLY thing making the index durable
  # and it runs in terminate/2, where a failure has no retry — so it gets a
  # counter. Bounded phase atoms only, never vault/user ids.
  @checkpoint_event [:engram, :crdt, :index_checkpoint]

  # #2306. The tail bounds, in one place. A claim encodes to a few hundred
  # bytes, so a tail held near 500 rows replays in one page (well under 1 MB of
  # ciphertext) and a 15k-note first sync folds about 30 times, each fold one
  # encode of the index (~2 MB at 10k notes), off the room loop. The byte bound
  # catches the rarer large update (a batch claim) that the row count would not.
  #
  # 1,000-row pages: each window read costs a transaction and a scan of the
  # user's tail ids, and at 200 rows a 15k-row single-client replay took 2.3 s
  # against main's 0.9 s; at 1,000 it takes 0.8-1.1 s. A page still holds at most
  # 1,000 rows' plaintext.
  @tail_defaults [fold_tail_rows: 500, fold_tail_bytes: 2_000_000, replay_page_rows: 1_000]

  defp limit(key) do
    :engram
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, @tail_defaults[key])
  end

  defp over_threshold?(rows, bytes),
    do: rows > limit(:fold_tail_rows) or bytes > limit(:fold_tail_bytes)

  @impl true
  # #1391. WITHOUT this callback the room was snapshot-only: everything since the
  # last checkpoint died with the process, and since #1151 step 2 made the map
  # authoritative for paths, that is committed path CLAIMS being lost — after
  # which projection drags the rows back to the superseded snapshot.
  #
  # Failure is logged and swallowed rather than raised: this runs inside the
  # room's update handling, so raising kills the room for every client on the
  # vault and loses MORE than the one update. The snapshot at checkpoint is
  # still taken, so a dropped tail row degrades to exactly the old behaviour
  # rather than to something worse.
  def update_v1(%{user_id: user_id, vault_id: vault_id} = state, update, _name, doc) do
    case Process.get(:index_replay_echoes, 0) do
      n when n > 0 ->
        # Our own bind replaying. Re-appending it would duplicate the tail.
        Process.put(:index_replay_echoes, n - 1)
        state

      _ ->
        do_update_v1(state, user_id, vault_id, update, doc)
    end
  end

  defp do_update_v1(state, user_id, vault_id, update, doc) do
    # Postpone the idle drain (#1152). Signalled for EVERY update, including one
    # whose tail append fails below: activity is about whether the room is in
    # use, not whether the write succeeded, and draining a room a client is
    # actively writing to is the churn the whole re-arm design avoids.
    #
    # Runs inside the room process, so the timer pid comes from the process
    # dictionary — `CrdtIndexDoc.start_link/1` put it there.
    case Process.get(:crdt_timer_pid) do
      pid when is_pid(pid) -> CrdtCheckpointTimer.notify_activity(pid)
      _ -> :ok
    end

    with {:ok, user} <- fetch_user(user_id),
         {:ok, row_id} <- append_tail(user, vault_id, update, state.last_row_id) do
      grow_tail(state, row_id, byte_size(update), doc)
    else
      :skipped ->
        state

      {:error, reason} ->
        emit_tail(:failed)

        Logger.error(
          "crdt index tail append failed: #{Metadata.safe_reason(reason)}",
          Metadata.with_category(:error, :sync, user_id: user_id, vault_id: vault_id)
        )

        state
    end
  end

  # Records the row this room just appended, and folds once the rows since the
  # last fold pass a limit (#2306). `folded_ids` is exactly what this room's
  # doc holds and the tail still has: a fold prunes those and nothing else.
  defp grow_tail(state, row_id, bytes, doc) do
    state = %{
      state
      | folded_ids: [row_id | state.folded_ids],
        last_row_id: row_id,
        tail_bytes: state.tail_bytes + bytes
    }

    if over_threshold?(length(state.folded_ids), state.tail_bytes),
      do: fold_async(state, doc),
      else: state
  end

  # A live or post-bind fold. Only the encode needs the doc, so only the encode
  # runs on the room's message loop; the snapshot read, merge, encrypt, upsert
  # and prune (several DB round trips) run in the room's folder process. Run
  # inline, a slow pool pushed `Identity.via_room` past its 5 s call into the
  # snapshot fallback, the documented two-decisions gap.
  #
  # ONE folder per room, so one fold in flight per room (delta review M1): a
  # task per crossing piled up behind the per-vault lock under a slow pool,
  # each holding a connection and a ~2 MB encode. Requests that arrive while a
  # fold runs are coalesced (`folder_loop/3`).
  #
  # A fold that is skipped, fails or never runs leaves its rows in the tail,
  # where the next bind replays and prunes them. The ids are handed off either
  # way, so a failing fold is retried a threshold of appends later, not on
  # every append.
  defp fold_async(%{user_id: user_id, vault_id: vault_id, folded_ids: ids} = state, doc) do
    case ensure_folder(state) do
      {:ok, folder} ->
        send(folder, {:fold, encode_state(doc, vault_id), ids})
        Map.merge(state, %{folded_ids: [], tail_bytes: 0, folder: folder})

      # `update_v1/4` promises to log and swallow: a MatchError here would kill
      # the room for every client on the vault. The ids stay, so the next
      # append (or `unbind/3`) folds them.
      {:error, reason} ->
        Logger.error(
          "crdt index fold not started: #{Metadata.safe_reason(reason)}",
          Metadata.with_category(:error, :sync, user_id: user_id, vault_id: vault_id)
        )

        state
    end
  end

  defp ensure_folder(%{folder: pid} = state) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: start_folder(state.user_id, state.vault_id)
  end

  defp ensure_folder(%{user_id: user_id, vault_id: vault_id}),
    do: start_folder(user_id, vault_id)

  defp start_folder(user_id, vault_id) do
    room = self()

    Task.Supervisor.start_child(Engram.TaskSupervisor, fn ->
      folder_loop(user_id, vault_id, Process.monitor(room))
    end)
  end

  # Not linked: the room traps exits, and an `{:EXIT, ...}` is not a message
  # `SharedDoc` expects. The folder watches the room instead, and drains what
  # it was sent before exiting with it.
  defp folder_loop(user_id, vault_id, room_ref) do
    receive do
      {:fold, encoded, ids} ->
        run_coalesced(user_id, vault_id, encoded, ids)
        folder_loop(user_id, vault_id, room_ref)

      {:DOWN, ^room_ref, :process, _, _} ->
        :ok
    end
  end

  # Every queued request is folded into the newest one: a later encode of the
  # same room's doc holds everything an earlier one did (the doc only grows),
  # so it covers the union of their ids.
  defp run_coalesced(user_id, vault_id, encoded, ids) do
    receive do
      {:fold, newer, more} -> run_coalesced(user_id, vault_id, newer, more ++ ids)
    after
      0 -> fold(user_id, vault_id, encoded, ids, false)
    end
  end

  defp fetch_user(user_id) do
    case Accounts.get_user(user_id) do
      nil -> {:error, :user_gone}
      user -> {:ok, user}
    end
  end

  # The row id is minted BEFORE encrypting because the AAD binds to it — the
  # same pre-allocation the tombstone path uses for row-id-bound AAD.
  defp append_tail(user, vault_id, update, after_id) do
    # #1341. This ENCRYPTS, so it carries the same hazard as the checkpoint, and
    # `Identity`'s "the room path needs no gate — it only mutates memory" stopped
    # being true the moment this callback existed. A row written after the sweep
    # has drained but before `final_flip` retires the old key is permanently
    # unreadable: nothing will ever re-wrap it.
    #
    # Skipping costs the claim only until the next checkpoint, which is gated
    # too and therefore leaves it in memory to be written afterwards. Writing an
    # old-dek row loses it forever.
    #
    # `check/1`: `user` comes from the `:user` cache, which learns of a lock
    # taken on another node only when its eviction lands.
    case RotationGate.check(user.id) do
      {:error, :rotation_in_progress} ->
        emit_tail(:skipped_rotation)
        :skipped

      _ ->
        do_append_tail(user, vault_id, update, after_id)
    end
  end

  defp do_append_tail(user, vault_id, update, after_id) do
    row_id = next_row_id(after_id)

    # dek_version records the version that actually wrapped THIS row, never a
    # constant: the rotation sweep stamps the new version, so a hardcoded 2
    # would disagree with the user's after the first rotation and be believed.
    dek_version = user.dek_version || Crypto.row_version_aad_bound()

    with {:ok, {ct, nonce}} <- Crypto.encrypt_index_update(update, user, row_id) do
      {:ok, _} =
        Repo.with_tenant(user.id, fn ->
          %VaultIndexUpdateLog{}
          |> VaultIndexUpdateLog.changeset(%{
            id: row_id,
            vault_id: vault_id,
            user_id: user.id,
            update_ciphertext: ct,
            update_nonce: nonce,
            dek_version: dek_version
          })
          |> Repo.insert!()
        end)

      emit_tail(:ok)
      {:ok, row_id}
    end
  rescue
    # `Repo.insert!` RAISES on any DB error, and under pool starvation so does
    # the checkout itself — neither is an {:error, _} the caller's `with` could
    # catch. Unrescued they kill the room for every client on the vault, and
    # `unbind`'s checkpoint then needs the same exhausted pool, so the update is
    # lost from memory AND from the tail. `unbind/3` rescues for exactly this
    # reason (the 2026-07-09 incident); match it.
    e -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # A row id that sorts after `after_id`, the newest row this room knows of
  # (bound over or appended). The replay walks the tail in id order and yrs does
  # not converge every out-of-order replay of one client's edits (a reversed
  # set/overwrite/delete chain loses a key), so one room's appends must sort in
  # append order. A bare UUIDv7 does not promise that: its low bits are random
  # within a millisecond, and its clock can step back or differ between the
  # nodes a `:global` room moves across. Bumping by one keeps the version and
  # variant bits (a carry out of the 62 random bits is the only way to lose
  # them).
  defp next_row_id(nil), do: UUIDv7.generate()

  defp next_row_id(after_id) do
    case UUIDv7.generate() do
      id when id > after_id ->
        id

      _ ->
        <<n::128>> = Ecto.UUID.dump!(after_id)
        Ecto.UUID.load!(<<n + 1::128>>)
    end
  end

  defp emit_tail(phase) do
    :telemetry.execute([:engram, :crdt, :index_tail], %{count: 1}, %{phase: phase})
    :ok
  end

  @impl true
  def bind(%{user_id: user_id, vault_id: vault_id} = state, _doc_name, doc) do
    # Mirrors CrdtPersistence.bind/3: trapping exits makes gen_server intercept
    # the supervisor's :shutdown on a deploy and run terminate/2 -> unbind,
    # instead of dying unflushed. Guarded on :"$initial_call" so a direct bind/3
    # from a bare test process does not leak trap_exit into the test, where it
    # would swallow linked-process crashes.
    if Process.get(:"$initial_call") != nil, do: Process.flag(:trap_exit, true)

    # get_user!/1 here, deliberately unlike unbind/3's get_user/1. A missing user
    # means the room must NOT start: raising fails the start, the client's frame
    # errors and it retries. unbind/3 is the opposite case — it runs during
    # teardown, where a purged user is an EXPECTED state and raising produced the
    # #954 error storm.
    user = Accounts.get_user!(user_id)

    {snapshot_echoed?, seen} = bind_snapshot(user, doc, vault_id, nil)

    # AFTER the snapshot, always — including when there is none. A vault that
    # has never checkpointed can still have tail rows, and those are the only
    # record of its claims (#1391). Outside the snapshot's transaction: the
    # replay opens one short transaction per page (#2306), where one spanning
    # the whole tail held its connection past DBConnection's 15 s limit in prod.
    # Each statement already saw its own snapshot under READ COMMITTED, so this
    # opens no window one transaction closed.
    replay = replay_tail(doc, user, vault_id)

    # Review finding 3 on #2306: a roomless fold that commits between the read
    # above and the pages folds rows into a NEW snapshot and prunes them, so the
    # pages never see them. Re-read, and apply the snapshot again if it moved:
    # a CRDT union, idempotent, and the new snapshot holds every row it pruned.
    {resnapshot_echoed?, _seen} = bind_snapshot(user, doc, vault_id, seen)

    # y_ex installs the doc update monitor BEFORE bind/3 runs
    # (`doc_server_worker.ex` monitor_update_v1 -> module.init -> bind), so every
    # `Yex.apply_update/2` above posts an `{:update_v1, ...}` to this room's own
    # mailbox and comes back through update_v1/4. Without this, binding would
    # APPEND the snapshot and the whole tail it just read back onto the tail:
    # n rows become 2n+1 every restart, each cycle also writing a row the size
    # of the entire index. On a vault whose room keeps dying — the exact case
    # the tail exists for — that is a spiral, not a leak.
    #
    # The count is safe to use as a credit because those messages are already in
    # the mailbox when init returns, and a mailbox is FIFO, so they are the next
    # `update_v1/4` calls this process makes. No client update can overtake them
    # because start_link has not returned yet.
    #
    # It counts CHANGES, not applies. An apply that changed nothing emits
    # nothing, so counting it would leave a credit behind that the next real
    # client claim spends — see `apply_echoing?/2`.
    echoes =
      Enum.count([snapshot_echoed?, resnapshot_echoed?], & &1) + replay.echoes

    Process.put(:index_replay_echoes, echoes)

    # C2: prune must never delete a row bind could not fold in. A row that fails
    # to decrypt today (a DekCache miss, a read racing a rotation) still holds a
    # claim that a later successful replay can recover — unless a checkpoint
    # deleted it in the meantime. So a fold prunes `folded_ids` (what this doc
    # holds) and nothing else, which also spares rows another room appended
    # during a `:global` netsplit (review finding 4).
    state =
      Map.merge(state, %{
        folded_ids: replay.applied,
        tail_bytes: replay.bytes,
        last_row_id: replay.last
      })

    # #2306: fold a large replay NOW. Left to `unbind/3`, a kill after this
    # bind (the OOM the replay itself nearly caused) replays it all again on
    # the next node. The echo credits above are unaffected: a fold never changes
    # the doc, so it posts no update.
    if over_threshold?(length(replay.applied), replay.bytes),
      do: fold_async(state, doc),
      else: state
  end

  # Applies the vault's snapshot unless it is the one `seen` (its nonce, unique
  # per encryption) already applied. Returns whether the apply will echo, and
  # the nonce now applied.
  defp bind_snapshot(user, doc, vault_id, seen) do
    {:ok, result} =
      Repo.with_tenant(user.id, fn ->
        case Repo.get(VaultIndexState, vault_id) do
          # No snapshot yet: a vault whose index room has never checkpointed.
          # The doc stays empty, which is the correct starting state.
          nil -> {false, seen}
          %VaultIndexState{state_nonce: ^seen} -> {false, seen}
          row -> {apply_snapshot(row, user, doc, vault_id), row.state_nonce}
        end
      end)

    result
  end

  # The graceful-exit fold: synchronous, since the room is going away, and the
  # only fold that enqueues projection (review finding 1). A live fold every
  # `fold_tail_rows` appends used to enqueue a full pass each time, about 30
  # per 15k-note first sync, for claims whose rows are already written.
  @impl true
  def unbind(%{user_id: user_id, vault_id: vault_id} = state, _doc_name, doc) do
    fold(user_id, vault_id, fn -> encode_state(doc, vault_id) end, state.folded_ids, true)
  end

  # The one fold every caller goes through: `unbind/3`, and `fold_async/2` for a
  # live room or a bind past the tail limits. `encoded` is the room's encoded
  # doc, or (for `unbind/3`) a function producing it, so that the encode's
  # exit is contained here too. Always returns :ok.
  defp fold(user_id, vault_id, encoded, ids, project?) do
    # get_user/1, NOT the bang variant. A deleted user or a vault force-purge is
    # an EXPECTED lifecycle state here — rows go while rooms are still exiting —
    # and raising turned that into a per-room error storm during a purge
    # (#954, 2026-07-07). Skip quietly.
    #
    # Resolved here rather than kept from bind/3: a room can outlive a DEK
    # rotation, and a stale struct carries the OLD wrapped dek. This is the
    # cached `get_user/1`; the rotation lock itself is read from the DB in
    # checkpoint/5.
    case Accounts.get_user(user_id) do
      nil ->
        :ok

      user ->
        encoded = if is_function(encoded, 0), do: encoded.(), else: encoded
        checkpoint(user, vault_id, encoded, ids, project?)
    end
  rescue
    # A DB failure does NOT surface as {:error, _} — Repo.insert_all RAISES, and
    # under pool starvation so does the checkout itself (the 2026-07-09 incident
    # frame). Unrescued, that escapes terminate/2 rather than reaching the
    # "loud" branch below. Both siblings guarantee unbind always returns :ok
    # (crdt_persistence.ex:264, crdt_checkpoint.ex:98); match them.
    e ->
      emit_checkpoint(:failed)

      # The index doc holds every path and title in the vault, so this rescue
      # has more user data in scope than most, not less.
      Logger.error(
        "crdt index checkpoint raised: #{Metadata.safe_reason(e)}",
        Metadata.with_category(:error, :sync, user_id: user_id, vault_id: vault_id)
      )

      :ok
  catch
    # An exit is not a raise, and `rescue` does not contain one.
    # `Yex.encode_state_as_update/1` runs through a GenServer call into the doc
    # worker (Yex.Doc.run_in_worker_process), so a dead worker or a call timeout
    # during shutdown arrives here. Escaping terminate/2 would turn a lost
    # checkpoint into an anonymous SharedDoc crash report carrying no vault_id.
    :exit, reason ->
      emit_checkpoint(:failed)

      Logger.error(
        "crdt index checkpoint exited: #{Metadata.safe_exit_reason(reason)}",
        Metadata.with_category(:error, :sync, user_id: user_id, vault_id: vault_id)
      )

      :ok
  end

  defp checkpoint(user, vault_id, encoded, ids, project?) do
    # #1341, and the note path names THIS leg as the likeliest to race:
    # `SessionInvalidator.disconnect_user/1` fires at the TOP of a rotation, so
    # rooms start draining while the sweep is still running. A checkpoint landing
    # between sweep_vault_index_states and final_flip writes an OLD-dek snapshot
    # over a row the sweep already re-wrapped — permanently undecryptable once
    # the old key retires. Re-reading the user does NOT close this: final_flip is
    # the last phase, so get_user still answers with the old wrapped dek
    # throughout the window.
    #
    # Skipping is right: the tail still holds everything since the last
    # checkpoint, so a skipped checkpoint costs a replay on the next bind rather
    # than the claims themselves. Writing an old-dek snapshot loses them outright.
    #
    # `check/1`: `user` comes from the `:user` cache, which learns of a lock
    # taken on another node only when its eviction lands.
    case RotationGate.check(user.id) do
      {:error, :rotation_in_progress} ->
        emit_checkpoint(:skipped_rotation)

        Logger.warning(
          "crdt index checkpoint skipped — dek rotation in progress vault_id=#{vault_id}",
          Metadata.with_category(:warning, :sync, user_id: user.id, vault_id: vault_id)
        )

        :ok

      _ ->
        write_snapshot(user, vault_id, encoded, ids, project?)
    end
  end

  defp emit_checkpoint(phase) do
    :telemetry.execute(@checkpoint_event, %{count: 1}, %{phase: phase})
    :ok
  end

  @doc """
  Hydrate a `Yex.Doc` from this vault's persisted snapshot.

  Returns an EMPTY doc when there is no snapshot yet — a vault whose index room
  has never checkpointed is not an error. A snapshot that exists and will not
  decrypt IS one, and is never silently downgraded to an empty doc: writing that
  back would replace the real index with nothing.

  Public for `Engram.Notes.Identity`, which rewrites the snapshot in place when no room
  is live. Both go through `persist_doc/3` so there is exactly one writer of the
  `vault_index_states` row.

  The doc carries the vault's server client id (`server_doc/1`), so it is for
  READING: a write through it outside `fold_roomless/3`'s lock would reuse that
  client id concurrently with another writer.
  """
  @spec load_doc(map(), String.t()) :: {:ok, Yex.Doc.t()} | {:error, term()}
  def load_doc(user, vault_id) do
    doc = server_doc(vault_id)

    # snapshot + tail ≡ bind/3's recipe. Teaching bind/3 to replay the tail and
    # NOT this would leave the roomless reader blind to every claim made since
    # the last checkpoint — which is precisely the state an ungraceful room
    # death creates, and precisely when `Identity` takes this path because
    # `:global` has no room to find.
    #
    # The consequences of the two disagreeing are not staleness. `Identity`
    # would accept a claim on a path a tail row already holds (returning success
    # where a conflict is owed), and a release would fail to remove an entry
    # that lives only in the tail, which the next bind then replays back — one
    # permanent path reservation per note.
    Repo.with_tenant(user.id, fn ->
      with :ok <- load_snapshot_into(doc, user, vault_id) do
        _ = replay_tail(doc, user, vault_id)
        {:ok, doc}
      end
    end)
    |> case do
      {:ok, result} -> result
      other -> other
    end
  end

  defp load_snapshot_into(doc, user, vault_id) do
    case Repo.get(VaultIndexState, vault_id) do
      nil ->
        :ok

      row ->
        with {:ok, snapshot} <- Crypto.decrypt_index_state(row, user) do
          case Yex.apply_update(doc, snapshot) do
            :ok -> :ok
            _ -> {:error, :corrupt_snapshot}
          end
        end
    end
  end

  @doc """
  Encode, size-check, encrypt and upsert `doc` as this vault's snapshot.

  Does NOT enqueue projection. A claim from `Engram.Notes.Identity` is followed
  immediately by the row write in the same call, so the common case needs no
  pass. Note the ordering: under claim-first the index and the rows explicitly
  do NOT agree at the moment this returns. A claim whose row write then FAILS is
  an orphan, and `Engram.Notes` enqueues projection for that case itself rather
  than leaving it to the next room checkpoint.
  """
  @spec persist_doc(map(), String.t(), Yex.Doc.t()) :: :ok | {:error, term()}
  def persist_doc(user, vault_id, doc) do
    with {:ok, encoded} <- encode_state(doc, vault_id),
         do: persist_encoded(user, vault_id, encoded)
  end

  defp persist_encoded(user, vault_id, encoded) do
    with :ok <- check_size(encoded, vault_id),
         {:ok, {ct, nonce}} <- Crypto.encrypt_index_state(encoded, user, vault_id) do
      upsert(user, vault_id, ct, nonce)
    end
  end

  # The doc every server-side (roomless) write goes through, with ONE Yjs client
  # id per vault instead of a random one per write. A state vector never drops a
  # client id, so a fresh `Yex.Doc.new()` per write grew it by one per claim: a
  # 15k-note first sync left ~15k ids, and every state-vector encode in the
  # replay paid for all of them (#2306).
  #
  # Reusing a client id is safe only if no two writers ever hold it with
  # different histories. That holds here: every write through this doc runs in
  # `fold_roomless/3` under the per-vault advisory lock, loads the persisted
  # snapshot plus tail first (so it continues the id's latest clock), and
  # either persists before the lock is released or persists nothing. Nothing
  # removes this id's items from the snapshot afterwards, because a room fold
  # MERGES into the stored snapshot rather than replacing it (`write_snapshot/5`).
  # Rooms keep random ids: two rooms can be live at once (a `:global` netsplit),
  # and must not share one.
  defp server_doc(vault_id) do
    Yex.Doc.with_options(%Yex.Doc.Options{
      client_id: :erlang.phash2({:crdt_index_server, vault_id}, 4_294_967_296),
      # "" not nil, as `CrdtBridge.new_doc/0` does: the NIF's success typing
      # takes a binary, and nil cascades a no_return through every caller.
      collection_id: ""
    })
  end

  defp fold_lock(vault_id), do: "crdt_index_fold:" <> vault_id

  @doc """
  The roomless equivalent of a checkpoint: load, mutate, persist, prune.

  `Identity` takes this path when `:global` finds no room for the vault. It has
  to honour the SAME fold-and-prune contract `write_snapshot/5` does, because
  `persist_doc/3` folds the replayed tail into the snapshot it writes. Folding
  without pruning leaves every one of those rows behind, duplicated inside the
  snapshot — and the next bind replays them as no-ops, which emit no
  `{:update_v1, ...}` and so mis-credit the echo suppressor (see
  `apply_echoing?/2`). One roomless write was enough to start silently dropping
  the next room session's claims.

  The whole fold runs in ONE transaction, so a mutation that cannot be persisted
  cannot prune either.

  Serialized per vault by a transaction-scoped advisory lock. `upsert/4`
  REPLACES the row, so two folds that loaded the same snapshot would each
  write it back minus only their own change, and the later one silently
  undoes the earlier. Concurrent roomless folds are routine: a
  `ReleaseIndexEntries` chain link, per-note delete releases and claims for
  one vault can run together, and the projection runs right after the room
  exits. The room fold (`write_snapshot/5`) takes the same lock and merges
  into what it finds.
  """
  @spec fold_roomless(map(), String.t(), (Yex.Doc.t() -> :ok | {:error, term()})) ::
          :ok | {:error, term()}
  def fold_roomless(user, vault_id, mutate) when is_function(mutate, 1) do
    Repo.with_tenant(user.id, fn ->
      :ok = Repo.advisory_lock!(fold_lock(vault_id))
      doc = server_doc(vault_id)

      with :ok <- load_snapshot_into(doc, user, vault_id) do
        # Prune exactly the rows this replay applied: not "every row of the
        # vault", which would take rows a live room appended after the read.
        replay = replay_tail(doc, user, vault_id)

        with :ok <- mutate.(doc),
             :ok <- persist_doc(user, vault_id, doc) do
          prune_tail(user, replay.applied)
          :ok
        end
      end
    end)
    |> case do
      {:ok, result} -> result
      other -> other
    end
  end

  # Prunes exactly `ids`: the rows this room's doc holds (replayed at bind or
  # appended since). Not a timestamp or "everything for this vault" range: an
  # update appended after the encode is NOT in the snapshot, and rows another
  # room appended (a `:global` netsplit) are in neither, so a range prune would
  # drop the claims the tail exists to protect.
  #
  # Under the same per-vault lock as `fold_roomless/3`, and MERGED into the
  # stored snapshot rather than replacing it. Replacing let the two overwrite
  # each other (a roomless write landing while the room was live vanished at
  # the room's next fold, #2176), and a merge is what keeps the server client
  # id's history intact (`server_doc/1`).
  defp write_snapshot(user, vault_id, encoded, ids, project?) do
    result =
      with {:ok, encoded} <- encoded do
        Repo.with_tenant(user.id, fn ->
          :ok = Repo.advisory_lock!(fold_lock(vault_id))

          with {:ok, merged} <- merge_stored(user, vault_id, encoded),
               do: persist_encoded(user, vault_id, merged)
        end)
        |> case do
          {:ok, result} -> result
          other -> other
        end
      end

    case result do
      :ok ->
        emit_checkpoint(:ok)
        prune_tail_safely(user, vault_id, ids)
        if project?, do: enqueue_projection(user.id, vault_id)
        :ok

      {:error, reason} ->
        emit_checkpoint(:failed)

        # Loud: this is the write that makes the index durable at all.
        Logger.error(
          "crdt index checkpoint failed: #{Metadata.safe_reason(reason)}",
          Metadata.with_category(:error, :sync, user_id: user.id, vault_id: vault_id)
        )

        :ok
    end
  end

  # The union of the stored snapshot and the room's encode, re-encoded from a
  # fresh doc so garbage collection drops overwritten and deleted content.
  # `Yex.merge_updates/1` does not: it keeps the first input's copy of a
  # struct, so merging `[stored, encoded]` carried every dead value forward,
  # and a room that is always live never compacted (delta review H1: 21x the
  # doc after 20 overwrites, growing toward the 16 MB cap). The fresh doc's
  # client id is random and nothing is written through it.
  defp merge_stored(user, vault_id, encoded) do
    case Repo.get(VaultIndexState, vault_id) do
      nil ->
        {:ok, encoded}

      row ->
        with {:ok, stored} <- Crypto.decrypt_index_state(row, user) do
          doc = Yex.Doc.new()

          with :ok <- Yex.apply_update(doc, stored),
               :ok <- Yex.apply_update(doc, encoded),
               do: encode_state(doc, vault_id)
        end
    end
  end

  defp enqueue_projection(user_id, vault_id) do
    # Project the index onto the notes path columns (#1151 step 2) — in a
    # worker, never here. This runs inside terminate/2 against a shutdown
    # budget, and a projection pass is N renames, each re-encrypting a path,
    # rewriting path_hmac, repathing Qdrant points and enqueueing link
    # rewrites. Doing that in a terminating process during a deploy stampede
    # loses the checkpoint AND the projection.
    #
    # Enqueued only after the snapshot is durably written, so the worker can
    # never read a snapshot older than the doc that triggered it. Unique over
    # PENDING jobs only, the same choice `Engram.Notes` makes for an orphan
    # claim: the worker's default spans `:executing`, which collapsed this
    # exit into a pass that had already read the older snapshot, leaving the
    # room's last changes unprojected. `schedule_in` lets that pass finish.
    _ =
      Enqueue.enqueue(
        Engram.Workers.ProjectVaultIndex.new(%{user_id: user_id, vault_id: vault_id},
          unique: [keys: [:vault_id], states: [:available, :scheduled, :retryable]],
          schedule_in: 5
        ),
        "project_vault_index"
      )

    :ok
  end

  defp check_size(encoded, vault_id) when byte_size(encoded) > @max_snapshot_bytes,
    do: {:error, {:snapshot_too_large, byte_size(encoded), vault_id}}

  defp check_size(_encoded, _vault_id), do: :ok

  # A doc that fails to encode is NOT checkpointed as empty: overwriting a good
  # snapshot with nothing is indistinguishable from a fresh vault on the next
  # bind, and the index would come back silently empty.
  defp encode_state(doc, vault_id) do
    case Yex.encode_state_as_update(doc) do
      {:ok, encoded} when is_binary(encoded) -> {:ok, encoded}
      {:error, reason} -> {:error, {:encode_failed, reason, vault_id}}
    end
  end

  # Replays every tail row for this vault and returns the ids that actually
  # applied, the echoes owed, the plaintext bytes applied and the newest id
  # seen (applied or skipped), which the room's next append must sort after.
  #
  # Paged (#2306): `IdWindows` walks the user's tail one `replay_page_rows`
  # id window at a time, each in its own short tenant transaction (or inside
  # the caller's, which `load_doc/2` and `fold_roomless/3` hold), so memory and
  # connection time are bounded by a page, not by the tail. The old shape, one
  # `Repo.all` of every row plus two state-vector encodes PER ROW, is what
  # OOM-killed prod web tasks on 2026-10-29.
  #
  # In id order rather than (inserted_at, id). Order is not load-bearing: Yjs
  # updates are commutative, and the prune is by the exact ids returned here.
  # Ids are UUIDv7 minted at append, so it is near insertion order anyway.
  #
  # A row that will not decrypt is SKIPPED, not fatal. Yjs updates are
  # commutative and idempotent, so the rest still converge; refusing to bind
  # over one bad row would take the whole vault's index down.
  @doc false
  @spec replay_tail(Yex.Doc.t(), map(), String.t()) ::
          %{
            applied: [Ecto.UUID.t()],
            skipped: [Ecto.UUID.t()],
            echoes: non_neg_integer(),
            bytes: non_neg_integer(),
            last: Ecto.UUID.t() | nil
          }
  def replay_tail(doc, user, vault_id) do
    acc = %{applied: [], skipped: [], echoes: 0, bytes: 0, last: nil}

    {:ok, acc} =
      tail_windows(user, acc, fn ids, acc ->
        # In id order, which is one room's append order (`next_row_id/1`):
        # one client's chain replayed row by row out of order can lose a key.
        rows =
          VaultIndexUpdateLog
          |> where([l], l.id in ^ids and l.vault_id == ^vault_id)
          |> order_by([l], asc: l.id)
          |> Repo.all()

        replay_page(doc, user, vault_id, rows, acc)
      end)

    %{acc | applied: Enum.reverse(acc.applied)}
  end

  # The user's tail, one id window per step (a user's tail spans their vaults;
  # each step filters to one). The window is keyed on the primary key, so a
  # statement returns at most one page whatever the tail's size.
  # A user with several vaults pays for windows holding other vaults' rows.
  # ponytail: the table has no `(user_id, id)` index, so a window read walks the
  # primary key past the cursor (every tenant's rows, filtered by user and RLS)
  # or the user's `user_id` index entries, ids only, no decrypt. Fine while the
  # live fold keeps tails near `fold_tail_rows`; add `(user_id, id)` if the
  # table outgrows it.
  defp tail_windows(user, acc, step) do
    IdWindows.reduce(
      {:user, user.id},
      VaultIndexUpdateLog,
      acc,
      fn ids, _ctx, acc -> {:cont, step.(ids, acc)} end,
      batch_size: limit(:replay_page_rows)
    )
  end

  # One page applied inside ONE doc transaction: one `{:update_v1, ...}` echo
  # and two state-vector encodes per page, where the old per-row apply paid two
  # encodes per row (an encode is the size of the doc's client set).
  #
  # Row by row inside the transaction rather than one `Yex.merge_updates/1` per
  # page: the merge cost ~5x the whole replay at 15k rows from one client
  # (#2306 review), and a row that fails to apply returns an error before it
  # integrates anything, so it is skipped alone without a fallback pass. The
  # price: a merge converges whatever the row order, row-by-row applies do not
  # (a reversed set/overwrite/delete chain loses a key), so the rows must come
  # in append order, which `next_row_id/1` and the `order_by` above give.
  defp replay_page(_doc, _user, _vault_id, [], acc), do: acc

  defp replay_page(doc, user, vault_id, rows, acc) do
    before_sv = Yex.encode_state_vector(doc)
    acc = %{acc | last: Enum.max([acc.last | Enum.map(rows, & &1.id)], &max_id/2)}

    acc =
      Yex.Doc.transaction(doc, fn ->
        Enum.reduce(rows, acc, fn row, acc ->
          case Crypto.decrypt_index_update(row, user) do
            {:ok, update} ->
              case Yex.apply_update(doc, update) do
                :ok ->
                  applied(acc, row.id, update)

                _ ->
                  drop_row(acc, row.id, user, vault_id)
              end

            {:error, reason} ->
              skip_row(acc, row.id, user, vault_id, {:undecryptable_row, reason})
          end
        end)
      end)

    echoed? = Yex.encode_state_vector(doc) != before_sv
    %{acc | echoes: acc.echoes + if(echoed?, do: 1, else: 0)}
  end

  # A row is prunable only if no row before it was skipped (delta review M2).
  # `Yex.apply_update/2` answers :ok for an update whose dependencies are
  # missing (it goes pending), so after a skipped row the later rows of that
  # client's chain "apply" without integrating, and a snapshot encode keeps
  # their pending structs but NOT their pending delete set. Pruning them lost
  # the deletes: once the skipped row replayed, a deleted entry came back. The
  # rows after a gap still apply to the doc; they just stay in the tail until
  # a replay with no gap folds them. Conservative across clients: one skipped
  # row withholds every later row of the vault, not only its own client's.
  defp applied(%{skipped: []} = acc, id, update),
    do: %{acc | applied: [id | acc.applied], bytes: acc.bytes + byte_size(update)}

  # Withheld rows' bytes are not counted either: they would re-trigger a bind
  # fold that cannot prune them.
  defp applied(acc, _id, _update), do: acc

  # A row that decrypts but will not apply is not a Yjs update and never will
  # be: nothing can make it integrate. Keeping it bought nothing and, under the
  # rule above, would have pinned every row behind it forever (delta review
  # M3), so the rows killed rooms leave behind piled up again. It goes into
  # `applied`, the list a fold prunes, so the next fold deletes it. Loud: this
  # is a lost update, and the operator needs the vault. It does not open a gap
  # (`skipped`): rows depending on it stay pending whatever we do.
  defp drop_row(acc, row_id, user, vault_id) do
    emit_tail(:corrupt_row)

    Logger.error(
      "crdt index tail row is not a Yjs update; dropping it at the next fold",
      Metadata.with_category(:error, :sync, user_id: user.id, vault_id: vault_id)
    )

    %{acc | applied: [row_id | acc.applied]}
  end

  # Canonical lowercase UUID strings compare in byte order; nil sorts first.
  defp max_id(nil, _b), do: false
  defp max_id(_a, nil), do: true
  defp max_id(a, b), do: a >= b

  # Whether this apply will actually post an `{:update_v1, ...}` back to us.
  #
  # yrs fires the update observer from the transaction COMMIT hook, and only
  # when the transaction changed the doc. `Yex.apply_update/2` answers `:ok`
  # either way, so counting APPLIES rather than CHANGES over-counts — and every
  # over-count is a permanent credit in `:index_replay_echoes` that silently
  # swallows one real client claim. Two ordinary states hit it: an empty
  # snapshot (a vault whose room bound and exited without a write), and a tail
  # row a roomless `Identity.via_snapshot` write already folded into the
  # snapshot.
  #
  # The state vector is the CONSERVATIVE signal. It advances iff new items were
  # integrated, and integrating new items always emits. A delete-only update can
  # emit without advancing it — that under-counts, which merely re-appends an
  # idempotent row to the tail. Over-counting loses a claim outright, so the
  # error is deliberately biased to the harmless direction.
  defp apply_echoing?(doc, update) do
    before_sv = Yex.encode_state_vector(doc)

    case Yex.apply_update(doc, update) do
      :ok -> {:ok, Yex.encode_state_vector(doc) != before_sv}
      other -> other
    end
  end

  # A skipped row (one that would not DECRYPT, which may be transient: a
  # DekCache miss, a read racing a rotation) is NOT dropped. It keeps its place
  # in the tail so a later bind, after the transient has cleared, can still
  # recover the claim. It is also LOGGED, not merely counted: a permanently
  # lost path claim that surfaces only as a Prometheus tick gives an operator
  # no vault to look at.
  defp skip_row(acc, row_id, user, vault_id, {phase, _} = reason) do
    emit_tail(phase)

    Logger.warning(
      "crdt index tail row skipped on replay: #{Metadata.safe_reason(reason)}",
      Metadata.with_category(:warning, :sync, user_id: user.id, vault_id: vault_id)
    )

    %{acc | skipped: [row_id | acc.skipped]}
  end

  defp prune_tail(_user, []), do: :ok

  defp prune_tail(user, ids) do
    # CHUNKED: `l.id in ^ids` binds one parameter per id, and the tail is
    # unbounded for a room that never checkpoints (see the moduledoc), so a
    # large enough fold would blow Postgres' parameter ceiling — and take a
    # checkpoint that had already succeeded down with it.
    count =
      ids
      |> Enum.chunk_every(5_000)
      |> Enum.reduce(0, fn chunk, acc ->
        {:ok, {n, _}} =
          Repo.with_tenant(user.id, fn ->
            VaultIndexUpdateLog
            |> where([l], l.id in ^chunk)
            |> Repo.delete_all()
          end)

        acc + n
      end)

    :telemetry.execute([:engram, :crdt, :index_tail], %{count: count}, %{phase: :pruned})
    :ok
  end

  # The snapshot is ALREADY durable when this runs, so a prune failure is a
  # tail-hygiene problem, not a checkpoint failure. Letting it propagate made
  # `unbind/3`'s rescue emit `checkpoint(:failed)` for a checkpoint that had in
  # fact succeeded, and skipped the ProjectVaultIndex enqueue — so `notes.path_*`
  # never converged to the snapshot that had just been written.
  #
  # Rescuing here is not swallowing a bug: the rows it fails to delete are
  # replayed as idempotent no-ops on the next bind, and the failure is logged
  # and counted under its own phase.
  defp prune_tail_safely(user, vault_id, ids) do
    prune_tail(user, ids)
  rescue
    e ->
      emit_tail(:prune_failed)

      Logger.error(
        "crdt index tail prune failed after a durable checkpoint: #{Metadata.safe_reason(e)}",
        Metadata.with_category(:error, :sync, user_id: user.id, vault_id: vault_id)
      )

      :ok
  end

  # FAIL LOUD, exactly as CrdtPersistence.bind/3 does for a note's snapshot.
  #
  # Binding an empty doc here would be the fail-OPEN choice: the room comes up
  # looking like a fresh vault, and the very next unbind/3 writes that empty doc
  # back over a snapshot we merely failed to READ. A transient failure — DEK
  # cache miss, a read racing a DEK rotation — becomes permanent loss of the
  # whole index. The tail log narrows the blast radius to whatever the last
  # checkpoint folded in; it does not make fail-open safe.
  #
  # Raising fails the room start instead. The client's frame errors and it
  # retries; a genuinely corrupt snapshot surfaces as a loud, repeated failure
  # rather than a vault that silently forgot every path it knew.
  #
  # Returns whether the apply will echo back through update_v1/4 — see
  # `apply_echoing?/2`. An EMPTY snapshot applies cleanly and emits nothing.
  defp apply_snapshot(row, user, doc, vault_id) do
    case Crypto.decrypt_index_state(row, user) do
      {:ok, snapshot} when is_binary(snapshot) ->
        {:ok, echoed?} = apply_echoing?(doc, snapshot)
        echoed?

      {:error, reason} ->
        Logger.error(
          "crdt index bind could not decrypt the snapshot: #{Metadata.safe_reason(reason)}",
          Metadata.with_category(:error, :sync, vault_id: vault_id)
        )

        raise "crdt index bind: snapshot decrypt failed vault_id=#{vault_id} reason=#{inspect(reason)}"
    end
  end

  # The row write itself REPLACES; the merging happens before it. A room fold
  # merges the stored snapshot into its encode under the per-vault lock
  # (`write_snapshot/5`), and `fold_roomless/3` loads the stored snapshot under
  # the same lock before it mutates. So two rooms during a netsplit heal, or a
  # room and a roomless write, no longer clobber each other's claims (#2306).
  #
  # Returns a result the `with` above can act on. Previously this discarded the
  # transaction result and returned a bare `:ok`, so the "loud" else-branch was
  # structurally incapable of seeing a write failure — the one failure that
  # actually costs the index. Zero rows is unreachable today (ON CONFLICT DO
  # UPDATE with no WHERE always affects one row, and an RLS WITH CHECK violation
  # raises rather than filtering), but UserDekRotation asserts the rowcount on
  # these same rows and two standards on one table is how the next person picks
  # the wrong one.
  defp upsert(user, vault_id, ct, nonce) do
    now = DateTime.utc_now()
    user_id = user.id

    result =
      Repo.with_tenant(user_id, fn ->
        Repo.insert_all(
          VaultIndexState,
          [
            [
              vault_id: vault_id,
              user_id: user_id,
              state_ciphertext: ct,
              state_nonce: nonce,
              # The version of the DEK that actually wrapped THIS blob, not a
              # constant. UserDekRotation stamps the row with the new version
              # when it re-wraps; a fixed 2 here would set it back on the next
              # checkpoint and disagree with the user's after a second rotation.
              # Nothing reads it today (decrypt_index_state/2 is unconditionally
              # AAD-bound), which is exactly why a wrong value would go unnoticed
              # until something did.
              dek_version: user.dek_version || Crypto.row_version_aad_bound(),
              inserted_at: now,
              updated_at: now
            ]
          ],
          on_conflict: {:replace, [:state_ciphertext, :state_nonce, :dek_version, :updated_at]},
          conflict_target: :vault_id
        )
      end)

    case result do
      {:ok, {1, _}} -> :ok
      {:ok, {n, _}} -> {:error, {:unexpected_row_count, n, vault_id}}
      {:error, reason} -> {:error, {:upsert_rolled_back, reason, vault_id}}
    end
  end
end
