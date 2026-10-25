defmodule Engram.Workers.ReleaseIndexEntries do
  @moduledoc """
  Drop `filemeta_v0` entries for notes that have been deleted (#1151 step 2).

  ## Why a job, when claiming is inline

  A CLAIM is the commit, so it must happen before the row moves and inline —
  see `Engram.Notes.Identity`. A RELEASE is the opposite: it is cleanup after
  the row is already gone, and it must not run before the delete is durable.

  That difference matters because the bulk delete paths run inside a
  transaction. `Engram.Folders.delete/4` and `Notes.batch_delete_folders/3`
  both wrap the cascade, and `Identity` reaches Postgres through
  `Repo.with_tenant/2`, which JOINS an in-flight transaction. Releasing inline
  from there breaks both ways:

  * **No live room** — the snapshot write joins the transaction and rolls back
    with it. If the notes leg commits but the release failed, the entries
    survive as permanent path reservations.
  * **Live room** — the room write is in MEMORY and does not roll back. If a
    later leg fails (the attachment leg in `Folders.delete/4` is the real
    case), the notes come back but their entries are gone. Live notes that the
    authority does not mention: projection is additive-corrective and never
    acts on absence, so they stay unclaimed forever and their paths are free
    for a different note to take.

  Enqueueing fixes both by construction. `Oban.insert/1` goes through the same
  repo, so the job rolls back with the transaction that created it and only
  runs once the delete is committed.

  It also replaces a discarded return value with a retry. The old call sites
  wrote `_ = Identity.release(...)`, so a release refused mid-rotation — the
  window when bulk deletes are most likely to be running — vanished silently
  and left one permanent reservation per note.

  ## Args carry ids, never paths

  `note_ids` are UUIDs. `oban_jobs.args` is unencrypted JSONB, and
  `NoPlaintextArgsTest` bans plaintext paths there. Releases are id-keyed
  anyway, so nothing here needs a path.

  ## Consistency

  A path is briefly still claimed by a deleted note between the commit and this
  job running. Nothing can *resurrect* a genuinely deleted note (projection's
  `get_note_by_id` is `scoped_live`, so the entry reads as an unknown note),
  and creating a file at that path is unaffected because creation does not
  claim. Only a RENAME onto that exact path inside the window is refused, and
  it succeeds on retry.

  That guarantee is what every caller BEFORE #1550 relied on: the row really
  is gone, permanently, by the time this job runs, because the caller enqueues
  it from inside (or right after) the transaction that deleted it. #1550's
  caller (`ProjectVaultIndex`) breaks that premise on purpose — it enqueues a
  release for a note it saw as MISSING, not deleted, and a missing note can
  still arrive: the create it's waiting on can land in the window between
  detection and this job running, especially under a `RotationGate` snooze.
  `Identity.release/3` deletes by note_id unconditionally with no such check,
  so `release/3` below re-verifies the note is still gone immediately before
  calling it — a no-op read for every pre-#1550 caller (their note really is
  gone), and the only thing standing between #1550's caller and un-indexing a
  note that just arrived.
  """
  use Oban.Worker, queue: :crdt_checkpoint, max_attempts: 5

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts
  alias Engram.Crypto.RotationGate
  alias Engram.Notes
  alias Engram.Notes.{Enqueue, Identity}
  alias Engram.Repo

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  # Ids per link, and so per index-room change. Chosen by measurement (PR
  # body of the chunking follow-up to #2164; 20k stale ids, 500/1k/2k/5k/10k
  # per job): a job's cost is dominated by a FIXED part that scales with the
  # whole index (snapshot decrypt/re-encrypt, or the room edit plus encrypted
  # tail append), ~0.2-0.5 s at 20-40k entries, while each extra id adds ~0.05
  # ms. So small chunks multiply that fixed cost: 20k ids took 20 s at 500 per
  # job and 5.7 s at 2,000, with the slowest job the same (~0.8 s) at both.
  # Above 2,000 the slowest job and the delete set broadcast to every
  # connected client (~4 B per id worst case, 8 KB here) keep growing for a
  # shrinking total-time win.
  #
  # Deliberately NOT `Notes`' 500-row chunk: that one bounds SQL bind params,
  # a different limit this job never reaches.
  @chunk_size 2_000

  # No @spec: dialyzer infers the exact `2000`, and a wider `pos_integer()`
  # is a `contract_supertype` it rejects.
  @doc "Max note ids per link of a release chain, i.e. per index-room change."
  def chunk_size, do: @chunk_size

  # Wall time one link may spend before handing the rest to a successor. A
  # chunk costs ~0.8 s at 20-40k index entries but its fixed part grows with
  # the index, so a whole-chain loop could outrun `timeout/1` (5 min) on a
  # huge vault and retry from the top forever. It is also how long a link
  # holds one `crdt_checkpoint` slot (3 per web node) before re-queueing
  # behind waiting `CheckpointNote` jobs, so it stays short: at 10 s, three
  # vaults storming at once block checkpoints for seconds, not a minute, and
  # a typical storm (34k ids, ~14 s) is two links.
  @default_link_budget_ms 10_000

  @doc "Wall-time budget per link, in ms. Config-overridable so tests can force a chain."
  def link_budget_ms,
    do: Application.get_env(:engram, :release_index_link_budget_ms, @default_link_budget_ms)

  @doc """
  Build ONE release job for `note_ids`, or `:skip` for none
  (`Enqueue.enqueue/3` no-ops on it).

  One job however many ids, on purpose. `perform/1` releases its ids
  `chunk_size/0` at a time, one index-room change per chunk, in series. If
  the job outlives `link_budget_ms/0` with ids left, it enqueues them as its
  successor and stops. The budget is checked between chunks, so a link runs
  for the budget plus one chunk (including any wait on the fold lock), far
  inside the 5 min timeout at ~0.8 s a chunk. Each chunk takes and releases
  its own transaction and fold lock, so nothing is held across chunks. A retry restarts from the top
  of the job's args, so it redoes up to one budget plus the failed chunk;
  each redone chunk re-reads which notes exist, so a re-release is a no-op
  and a note that arrived in between is skipped. A chain runs one link at a
  time. Enqueueing every chunk up front instead let a storm (17 chunks at 34k
  ids) fill every `crdt_checkpoint` slot with jobs that all wait on the same
  per-vault fold lock in `CrdtIndexPersistence`, each holding a pooled DB
  connection while `CheckpointNote` jobs starved behind them. It is also one
  atomic insert, so a caller never ends up with half its releases queued: a
  DB error raises and rolls the caller's transaction back, and any other
  `{:error, _}` is logged and counted by `Enqueue.enqueue/3`
  (`[:engram, :notes, :enqueue, :failed]`).
  """
  @spec new_for(String.t(), String.t(), [String.t()]) :: Ecto.Changeset.t() | :skip
  def new_for(_user_id, _vault_id, []), do: :skip

  def new_for(user_id, vault_id, note_ids),
    do: new(%{user_id: user_id, vault_id: vault_id, note_ids: note_ids})

  @doc """
  Queue the release of `note_ids` for `vault_id`. Every release goes through
  here, so they coalesce per vault: when the vault already has a release job
  waiting to run, the ids join it instead of queueing a job of their own.

  Each job rewrites the whole index once per chunk, a fixed cost that scales
  with the index, so the number of JOBS is what costs. Deleting K notes one
  request at a time used to queue K jobs: K full rewrites (2026-10-24 speed
  audit, `Notes.finish_tombstone/5`). Now a burst of deletes lands in the one
  pending job, and the queue stays the throttle (`oban-scheduling-model.md`):
  the busier the vault, the bigger each job.

  Only a job still `available` or `scheduled`, holding room for the ids
  within `chunk_size/0`, is joined. One already running read its args at
  fetch, so it is never extended; a full one is left alone. Either way the
  ids then get a fresh job. The pending row is taken `FOR UPDATE SKIP LOCKED`, and the UPDATE
  re-checks the state under that lock, so a job Oban fetches meanwhile is not
  joined either. Inside a caller's transaction the joined args commit or roll
  back with it, exactly like the insert they replace.
  """
  @spec enqueue(String.t(), String.t(), [String.t()]) :: {:ok, term()} | {:error, term()}
  def enqueue(_user_id, _vault_id, []), do: {:ok, :skipped}

  def enqueue(user_id, vault_id, note_ids) do
    case join_pending(user_id, vault_id, note_ids) do
      {1, _} -> {:ok, :joined}
      {0, _} -> Enqueue.enqueue(new_for(user_id, vault_id, note_ids), "release_index_entries")
    end
  end

  @pending_states ~w(available scheduled)

  # Runs on every note delete, usually to find nothing, so it must stay an
  # index probe: state + queue are the leading columns of Oban's
  # `oban_jobs_state_queue_priority_scheduled_at_id_index`. No ORDER BY: any
  # pending job of the vault will do (QueryPlan test in the coalesce suite).
  #
  # A job takes joined ids only up to `chunk_size/0`, one index-room change's
  # worth. A full one (a chain successor carrying the rest of a storm, a
  # folder delete) is left alone and the release gets its own job, so no
  # pending job grows without bound while its vault keeps deleting.
  defp join_pending(_user_id, _vault_id, note_ids) when length(note_ids) >= @chunk_size,
    do: {0, nil}

  defp join_pending(user_id, vault_id, note_ids) do
    room = @chunk_size - length(note_ids)
    queue = __opts__() |> Keyword.fetch!(:queue) |> to_string()

    pending =
      from(j in Oban.Job,
        where: j.state in ^@pending_states and j.queue == ^queue,
        where: j.worker == ^inspect(__MODULE__),
        where: fragment("? @> ?", j.args, ^%{"user_id" => user_id, "vault_id" => vault_id}),
        where:
          fragment("jsonb_array_length(coalesce(? -> 'note_ids', '[]'::jsonb))", j.args) <= ^room,
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED",
        select: j.id
      )

    from(j in Oban.Job,
      where: j.id in subquery(pending) and j.state in ^@pending_states,
      update: [
        set: [
          args:
            fragment(
              "jsonb_set(?, '{note_ids}', coalesce(? -> 'note_ids', '[]'::jsonb) || to_jsonb(?::text[]))",
              j.args,
              j.args,
              ^note_ids
            )
        ]
      ]
    )
    |> Repo.update_all([])
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id} = args}) do
    note_ids = Map.get(args, "note_ids", [])

    case Accounts.get_user(user_id) do
      # Purged mid-flight (#954). The vault's index went with it.
      nil ->
        :ok

      user ->
        # The snapshot path encrypts, so it carries #1341. Snoozing rather than
        # skipping is the point of being a job: a skipped release leaves a
        # permanent path reservation, and rotations are exactly when bulk
        # deletes keep running. `check/1`: `user` is the cached row, which
        # may not have seen another node's lock yet.
        case RotationGate.check(user.id) do
          {:error, :rotation_in_progress} -> {:snooze, 30}
          {:error, :user_not_found} -> :ok
          :ok -> user |> release(vault_id, note_ids) |> snooze_on_rotation()
        end
    end
  end

  # A rotation that starts mid-link refuses the next chunk's release. That is
  # the same wait as the gate above, not a failure: snooze rather than burn
  # one of the 5 attempts (the retry redoes the link's released chunks as
  # no-ops).
  defp snooze_on_rotation({:error, :rotation_in_progress}), do: {:snooze, 30}
  defp snooze_on_rotation(result), do: result

  defp release(user, vault_id, note_ids) do
    release_chunks(
      user,
      vault_id,
      note_ids,
      System.monotonic_time(:millisecond) + link_budget_ms()
    )
  end

  defp release_chunks(user, vault_id, note_ids, deadline) do
    {chunk, rest} = Enum.split(note_ids, @chunk_size)

    # See "Consistency" above: a note this job was told is gone may have
    # arrived since it was enqueued. `%{id: vault_id}` is the same
    # bare-map-as-vault shape `ProjectVaultIndex` uses. ONE metadata read per
    # chunk, not a full-row fetch and content decrypt per id.
    #
    # A failed read or release returns the error and Oban retries THIS job
    # with its args intact, so no id is lost; chunks it already released are
    # redone as no-ops. The successor is enqueued only after the last chunk
    # this link ran succeeded, and a failed insert retries this link too.
    with {:ok, present} <- Notes.get_note_meta_by_ids(user, %{id: vault_id}, chunk),
         :ok <- Identity.release(user, vault_id, Enum.reject(chunk, &Map.has_key?(present, &1))) do
      cond do
        rest == [] ->
          :ok

        System.monotonic_time(:millisecond) < deadline ->
          release_chunks(user, vault_id, rest, deadline)

        true ->
          enqueue_successor(user, vault_id, rest)
      end
    end
  end

  # ponytail: a successor carries every remaining id, so args written over a
  # chain are about (ids) x (links) / 2, and links = chain wall time / budget.
  # A 34k storm is two links. The worst case the 16 MB index allows (~400k
  # ids, ~200 chunks at a few s each) is tens of links and a few hundred MB
  # of args over the whole chain: the price of a short slot hold. Upgrade
  # path if that shows up: a cursor over a table of pending releases.
  #
  # Inserted as its own job, never joined into another (a link never extends
  # itself). Once queued, later releases for the vault may join it, but only
  # up to `chunk_size/0` ids (`enqueue/3`), so a successor already carrying
  # more than a chunk takes nothing more.
  #
  # The insert commits on its own. If the node dies after it but before Oban
  # acks this job, the rescued retry inserts a second successor, so two links
  # can briefly run for one vault. Safe (the fold lock serializes them and
  # releases are idempotent), just not "one link at a time" in that window.
  defp enqueue_successor(user, vault_id, rest) do
    case Enqueue.enqueue(new_for(user.id, vault_id, rest), "release_index_entries") do
      {:ok, _job} -> :ok
      {:error, _} = err -> err
    end
  end
end
