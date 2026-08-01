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
    unique: [keys: [:note_id], states: :incomplete]

  alias Engram.{Accounts, Crypto, Repo}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, CrdtPersistence, CrdtRegistry, Note}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    %{"user_id" => user_id, "vault_id" => vault_id, "note_id" => note_id} = args

    # A live room re-opened for this note between enqueue and run — it owns
    # materialization. Snooze rather than return :ok: skipping would DROP this
    # deferred checkpoint, and if the reopened room is then torn down
    # non-gracefully (crash / node kill) its edits would stay unmaterialized in
    # notes.content until the next bind. Snoozing keeps the job alive so it runs
    # once the room is gone (idempotent compaction; deduped by the unique key).
    if CrdtRegistry.lookup(note_id) != nil do
      {:snooze, 60}
    else
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
                from_snapshot? =
                  case Crypto.decrypt_crdt_state(note, user) do
                    {:ok, snapshot} when is_binary(snapshot) ->
                      :ok = Yex.apply_update(doc, snapshot)
                      true

                    _ ->
                      false
                  end

                applied_ids = CrdtPersistence.replay_tail(doc, user, note_id)
                {from_snapshot? or applied_ids != [], applied_ids}
            end
          end)

        # Only materialize when the note actually has CRDT state. A note opened
        # but never edited has no snapshot and no tail, so the doc rebuilds
        # EMPTY; checkpointing an empty doc would blank notes.content. In that
        # case notes.content is already authoritative, so there is nothing to do.
        if has_state? do
          {:ok,
           %{
             user_id: user_id,
             vault_id: vault_id,
             note_id: note_id,
             doc: doc,
             prune_ids: applied_ids
           }}
        else
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
