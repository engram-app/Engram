defmodule Engram.Workers.CheckpointNote do
  @moduledoc """
  Oban worker: durable, bounded overflow for CRDT unbind checkpoints.

  When a reconnect storm terminates more rooms at once than the inline
  `Engram.Notes.CheckpointGate` allows, `CrdtPersistence.unbind/3` enqueues this
  job instead of checkpointing synchronously. The queue concurrency
  (`crdt_checkpoint: 3`) bounds how many run at once so they cannot exhaust the
  DB pool. Excess jobs wait in Postgres, not as BEAM processes holding
  connections. Per-note `unique` dedup collapses a storm of same-note
  terminations into a single job.

  The job runs later and cannot see the in-memory Yjs doc, so it rebuilds the
  doc from durable state (snapshot + tail-log, `bind/3`'s recipe) and calls
  `CrdtCheckpoint.checkpoint/5`. Loss-free because the tail-WAL is never pruned
  until a checkpoint succeeds.
  """
  use Oban.Worker,
    queue: :crdt_checkpoint,
    max_attempts: 3,
    unique: [keys: [:note_id], states: :incomplete],
    # A job snoozed behind a live room ABSORBS later enqueues for its note
    # (unique across `:incomplete`). Without this, an absorbed room-exit enqueue
    # waits out the rest of the 60 s snooze; with it, the insert re-times the
    # snoozed job to the new job's run time.
    replace: [scheduled: [:scheduled_at]]

  import Ecto.Query, only: [from: 2]

  alias Engram.{Accounts, Crypto, Repo}
  alias Engram.Crypto.RotationGate
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, CrdtPersistence, CrdtRegistry, Note}

  require Logger

  # How long after a room exit its checkpoint runs. The exit enqueues from
  # inside the room's own shutdown, while it is still registered in `:global`;
  # running at once would find that dying room and snooze 60 s. Long enough
  # for the room to deregister, short enough that readers of notes.content
  # (REST, MCP, search) catch up within seconds.
  @room_exit_delay_s 5

  @doc "Seconds between a room exit and the checkpoint it owes."
  def room_exit_delay_s, do: @room_exit_delay_s

  @doc """
  The overflow checkpoint a room exit owes when the inline gate is full. If a
  snoozed job for the note already exists, it is re-timed (see `replace`)
  rather than left at its snooze deadline.
  """
  def for_room_exit(args), do: new(args, schedule_in: @room_exit_delay_s)

  @doc """
  After a room's own inline checkpoint: re-time any job for the note that is
  snoozed behind this (now exiting) room. Its work is usually already done, so
  it runs as cheap compaction instead of reading as owed for up to a minute.
  Enqueues nothing when no job is pending.
  """
  def retime_snoozed(note_id) do
    run_at = DateTime.add(DateTime.utc_now(), @room_exit_delay_s, :second)

    {count, _} =
      from(j in Oban.Job,
        where: j.worker == ^inspect(__MODULE__),
        where: j.state == "scheduled",
        where: j.scheduled_at > ^run_at,
        where: fragment("? ->> 'note_id'", j.args) == ^to_string(note_id)
      )
      |> Repo.update_all(set: [scheduled_at: run_at])

    count
  end

  # BEST-EFFORT here, unlike every other worker. Oban implements `timeout/1`
  # with `:timer.exit_after/2`, and an exit signal is only handled when the
  # process yields. This worker replays Yjs updates through y_ex, whose 131
  # NIFs are all plain `#[rustler::nif]` — none dirty-scheduled — so a process
  # inside `Yex.apply_update/2` cannot be preempted and will hold its slot past
  # the deadline until the NIF returns. The timeout still covers everything
  # around the replay (the DB reads, the encrypt, the commit), which is where
  # the queue's blocking work otherwise lives. See #1496.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{"user_id" => user_id, "vault_id" => vault_id, "note_id" => note_id} = args

    cond do
      # #1341. This worker encrypts crdt_state, so running it mid-rotation writes
      # a snapshot under the OLD DEK over one the sweep has already rewrapped —
      # re-creating exactly the un-openable note the rotation fix exists to
      # prevent. Every other DEK-touching worker already gates; this one did not.
      # (The room-unbind checkpoint is a separate leg of the same race and is not
      # reachable from here; tracked on the issue.)
      RotationGate.check(user_id) == {:error, :rotation_in_progress} ->
        {:snooze, 60}

      # A live room re-opened for this note between enqueue and run — it owns
      # materialization. Snooze rather than return :ok: skipping would DROP this
      # deferred checkpoint, and if the reopened room is then torn down
      # non-gracefully (crash / node kill) its edits would stay unmaterialized in
      # notes.content until the next bind. Snoozing keeps the job alive so it runs
      # once the room is gone (idempotent compaction; deduped by the unique key).
      CrdtRegistry.lookup(note_id) != nil ->
        {:snooze, 60}

      true ->
        case rebuild_detached(user_id, vault_id, note_id) do
          {:ok, token} -> finalize(token)
          :skip -> :ok
        end
    end
  end

  @doc """
  Rebuild the detached doc from durable state (snapshot + tail-log, `bind/3`'s
  recipe) AND capture the prune watermark in the SAME transaction. Returns an
  opaque token for `finalize/1`, or `:skip` when there is nothing to checkpoint
  (deleted user, deleted note, or a note with no CRDT state — see the has_state?
  gate below).

  Split out from `finalize/1` so the two-transaction window between rebuild and
  persist is explicit and testable: a tail row that lands AFTER this rebuild
  must NOT be pruned by the later checkpoint (#285). We capture the ids of the
  tail rows actually folded into `doc` and hand them to checkpoint as the exact
  prune set — never a `max(inserted_at)` range, which can tie within a clock
  tick and prune an unfolded concurrent append.
  """
  @spec rebuild_detached(String.t(), String.t(), String.t()) :: {:ok, map()} | :skip
  def rebuild_detached(user_id, vault_id, note_id) do
    # Deleted user is an expected lifecycle state (vault purge) — skip.
    case Accounts.get_user(user_id) do
      nil ->
        :skip

      user ->
        # Create the doc OUTSIDE the transaction (it is a mutable NIF resource)
        # and mutate it inside, mirroring bind/3: apply the snapshot, replay the
        # tail, and record the ids of the rows folded in.
        {:ok, doc} = CrdtBridge.doc_from_state(nil)

        {:ok, {has_state?, applied_ids}} =
          Repo.with_tenant(user_id, fn ->
            case Repo.get(Note, note_id) do
              nil ->
                {false, []}

              %Note{} = note ->
                case Crypto.decrypt_crdt_state(note, user) do
                  {:ok, snapshot} when is_binary(snapshot) ->
                    :ok = Yex.apply_update(doc, snapshot)
                    applied_ids = CrdtPersistence.replay_tail(doc, user, note_id, vault_id)
                    {true, applied_ids}

                  # No snapshot at all — legitimate for a note that has never
                  # been checkpointed. bind/3 documents the same case: the tail
                  # IS the doc's whole history, so replaying it is complete.
                  {:ok, nil} ->
                    applied_ids = CrdtPersistence.replay_tail(doc, user, note_id, vault_id)
                    {applied_ids != [], applied_ids}

                  # A snapshot that will not decrypt is NOT the same as no
                  # snapshot, and treating it as one is how a note loses its
                  # body. The tail holds deltas that sit ON TOP of that
                  # snapshot; replaying them onto an empty doc yields a
                  # base-less fragment, and this worker would then materialize
                  # that fragment over notes.content and prune the tail that
                  # proved it wrong. bind/3 raises on this exact signal
                  # (unreadable != absent); the detached path used to swallow
                  # it. Skip: nothing is written, nothing is pruned, and the
                  # row keeps every byte it had. #1341.
                  {:error, reason} ->
                    Logger.warning(
                      "crdt checkpoint skipped — unreadable snapshot note_id=#{note_id} reason=#{Metadata.safe_reason(reason)}",
                      Metadata.with_category(:warning, :sync,
                        note_id: note_id,
                        reason: Metadata.safe_reason(reason)
                      )
                    )

                    {:unreadable, []}
                end
            end
          end)

        # Only materialize when the note actually has CRDT state. A note opened
        # but never edited has no snapshot and no tail, so the doc rebuilds
        # EMPTY; checkpointing an empty doc would blank notes.content. In that
        # case notes.content is already authoritative, so there is nothing to do.
        # `:unreadable` is a THIRD state, not a falsy one — see above.
        case has_state? do
          true ->
            {:ok,
             %{
               user_id: user_id,
               vault_id: vault_id,
               note_id: note_id,
               doc: doc,
               prune_ids: applied_ids
             }}

          _ ->
            :skip
        end
    end
  end

  @doc """
  Persist a token produced by `rebuild_detached/3`.

  Passes `:prune_ids` — the exact tail rows this doc folded — so
  `CrdtCheckpoint.checkpoint/5` prunes ONLY them. Without it (the pre-#285
  behaviour) checkpoint re-queries `max(inserted_at)` at persist time; a tail
  row that landed in the window after the rebuild — or that ties the watermark's
  microsecond — would then be pruned UNfolded, permanently destroying an acked
  edit and regressing the served head.

  No @spec: the token's concrete map shape makes a hand-written `map()` contract
  a supertype of the success typing (contract_supertype) — same reason
  `CrdtTransport.load_doc/3` omits its spec.
  """
  def finalize(%{user_id: u, vault_id: v, note_id: n, doc: doc, prune_ids: ids}) do
    CrdtCheckpoint.checkpoint(u, v, n, doc, prune_ids: ids)
  end
end
