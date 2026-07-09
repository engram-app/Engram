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
    # materialization (its own timer/unbind will checkpoint). Skip to avoid
    # racing the live doc with a rebuilt-from-DB (possibly staler) copy.
    if CrdtRegistry.lookup(note_id) != nil do
      :ok
    else
      # Deleted user is an expected lifecycle state (vault purge) — skip.
      case Accounts.get_user(user_id) do
        nil -> :ok
        user -> rebuild_and_checkpoint(user, user_id, vault_id, note_id)
      end
    end
  end

  defp rebuild_and_checkpoint(user, user_id, vault_id, note_id) do
    # Create the doc OUTSIDE the transaction (it is a mutable NIF resource) and
    # mutate it inside, mirroring bind/3: apply the snapshot, replay the tail.
    {:ok, doc} = CrdtBridge.doc_from_state(nil)

    {:ok, has_state?} =
      Repo.with_tenant(user_id, fn ->
        case Repo.get(Note, note_id) do
          nil ->
            false

          %Note{} = note ->
            from_snapshot? =
              case Crypto.decrypt_crdt_state(note, user) do
                {:ok, snapshot} when is_binary(snapshot) ->
                  :ok = Yex.apply_update(doc, snapshot)
                  true

                _ ->
                  false
              end

            tail_count = CrdtPersistence.replay_tail(doc, user, note_id)
            from_snapshot? or tail_count > 0
        end
      end)

    # Only materialize when the note actually has CRDT state. A note opened but
    # never edited has no snapshot and no tail, so the doc rebuilds EMPTY;
    # checkpointing an empty doc would blank notes.content. In that case
    # notes.content is already authoritative, so there is nothing to do.
    if has_state? do
      CrdtCheckpoint.checkpoint(user_id, vault_id, note_id, doc)
    else
      :ok
    end
  end
end
