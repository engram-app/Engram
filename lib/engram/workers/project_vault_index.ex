defmodule Engram.Workers.ProjectVaultIndex do
  @moduledoc """
  Oban worker: project a vault's `filemeta_v0` index onto the `notes` path
  columns (#1151 step 2).

  This is what keeps everything that is NOT the CRDT working against a
  client-owned index: REST, search and MCP all answer "what is this note's
  path" from `notes.path_*`, never from Yjs state — exactly as `CrdtCheckpoint`
  projects note CONTENT for the same reason.

  ## Additive-corrective, and never acting on absence

  Projection walks the INDEX ENTRIES and corrects the row each one names. It
  does not walk the notes and ask whether the index still mentions them.

  A reconcile-by-absence implementation would read an empty index as "this
  vault has no files" and delete the vault. Being additive-corrective means
  projection can never delete a note, and never touches one the index does not
  mention.

  Note what this does NOT claim. An earlier version of this doc argued the
  feature was inert "because no client writes the index yet". That is a
  statement about the client we ship, not about what the server accepts —
  `crdt_channel.ex`'s `crdt_index_msg` handler relays any well-formed frame
  from any authenticated socket on the vault. Inertness here is a property of
  the WORKER (empty in, nothing out), not of the system.

  ## It iterates to a fixpoint, because one pass is not enough

  Entries interact through the unique `(user, vault, path_hmac)` constraint.
  A CHAIN — note A wants the path note B currently holds, while B is moving
  elsewhere — converges in one pass only if B is processed first.

  That is not a coin flip. `Yex.Map.to_map/1` returns a plain map, and Erlang
  small maps (<= 32 keys) iterate in TERM order, so entries are visited sorted
  by target path — which for a chain is reliably the losing order. Small vaults
  hit the bad case every time, reproducibly.

  So a pass that applied something AND still has conflicts is re-run, up to
  `#{5}` passes. A SWAP (A wants B's path, B wants A's) cannot converge at all:
  `rename_note/4` has no temp-path staging, so both sides collide on every
  pass. The loop halts on a pass with zero progress and reports `unresolved`,
  rather than re-logging the same two warnings forever.

  ## Why a worker, not the checkpoint

  `CrdtIndexPersistence.unbind/3` runs inside `terminate/2` against a shutdown
  budget. A projection pass is N renames, and `Notes.rename_note/4` re-encrypts
  the path, rewrites `path_hmac`, repaths Qdrant points and enqueues link
  rewrites. Doing that in a terminating process during a deploy stampede loses
  the checkpoint AND the projection.

  Per-vault `unique` collapses a room-exit storm into one job **within Oban's
  default 60s window** — not forever. Do not "fix" that to `period: :infinity`:
  a later checkpoint enqueueing a fresh pass is what heals a chain the previous
  run left one rename short.

  ## Consistency it actually provides

  Eventually consistent with the last PERSISTED snapshot. The job may execute
  after a new room has bound that snapshot and moved on, in which case it
  applies paths the live room has already superseded; the next checkpoint's run
  corrects that. It is NOT a claim that the worker sees the newest doc.

  ## Why it goes through `rename_note/4`

  Writing `path_ciphertext`/`path_nonce`/`path_hmac` directly would be a second
  path writer, and this repo has an exactly-one-rewriter invariant.
  `rename_note/4` pre-checks the unique constraint and answers
  `{:error, :conflict}` rather than crashing, and carries the Qdrant repath and
  link-rewrite legs with it.
  """
  use Oban.Worker,
    queue: :crdt_checkpoint,
    max_attempts: 3,
    unique: [keys: [:vault_id], states: :incomplete]

  alias Engram.{Accounts, Cache, Crypto, Notes, Repo}
  alias Engram.Crypto.RotationGate
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtIndexDoc, Enqueue, VaultIndexState}
  alias Engram.Workers.ReleaseIndexEntries

  require Logger

  # Bounds the fixpoint loop. A chain of N renames needs at most N passes, so a
  # chain longer than this is left PARTIALLY applied and resumes on the next
  # checkpoint's run — which is legitimate, and is the same property the
  # per-vault `unique` window relies on. The cap is here so a swap (which cannot
  # converge at all) stops churning, not because 6 rounds means failure.
  @max_passes 5

  # #1550: a client can claim a path before `crdt_create` is acked. If the
  # create never lands, the claim outlives it and names a note that will never
  # exist — projection then reports the same entry unresolved on every run
  # forever, which is the "permanently wedged" bug. Four of six creates in the
  # incident that filed #1550 self-healed within 8 minutes; the two that didn't
  # were still unresolved 16+ hours later. An hour is comfortably past any
  # observed legitimate delay and comfortably short of "permanent", so treat an
  # entry as abandoned (never seen a matching row, id older than this) rather
  # than in flight. Tunable — raise it if a slower create path proves 1h too
  # eager.
  @stale_claim_grace_ms :timer.hours(1)

  @event [:engram, :crdt, :index_projection]

  # See `Engram.Cache.Registry` for the window and its per-node ceiling.
  @released_cache :released_index_claims

  # Ids named in the one summary line per run. Bounded so a 15k-id storm is
  # one short line, not a 15k-element list.
  @log_sample 5

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
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id}}) do
    case Accounts.get_user(user_id) do
      nil ->
        # Purged mid-flight. Expected, not exceptional (#954) — but counted, so
        # a spike is visible rather than inferred.
        emit(:user_gone)
        :ok

      user ->
        # Decrypts the index snapshot, so it must not run mid-rotation against a
        # key the sweep is moving underneath it (#1341). `check/1`: `user` is
        # the cached row, which may not have seen another node's lock yet.
        case RotationGate.check(user.id) do
          {:error, :rotation_in_progress} ->
            emit(:snoozed_rotation)
            {:snooze, 30}

          _ ->
            project(user, vault_id)
        end
    end
  end

  defp project(user, vault_id) do
    case load_entries(user, vault_id) do
      {:ok, entries} ->
        run(user, vault_id, entries)

      :none ->
        emit(:no_snapshot)
        :ok

      # PERMANENT: a snapshot that will not decrypt, or that decrypts to bytes
      # Yjs rejects, will not fix itself. Retrying burns attempts to reach the
      # same place, and the rows are untouched either way.
      {:error, permanent} when permanent in [:decrypt_failed, :corrupt_snapshot] ->
        emit(permanent)

        Logger.error(
          "vault index projection cannot read the snapshot: #{inspect(permanent)}",
          Metadata.with_category(:error, :sync, user_id: user.id, vault_id: vault_id)
        )

        :ok

      # TRANSIENT until proven otherwise. get_dek/1 fails this way for a KMS
      # outage or a cache miss under load; the original catch-all classified
      # those as permanent and discarded a vault's projection over a blip.
      {:error, reason} ->
        Logger.error(
          "vault index projection failed to load, will retry: #{Metadata.safe_reason(reason)}",
          Metadata.with_category(:error, :sync, user_id: user.id, vault_id: vault_id)
        )

        {:error, reason}
    end
  end

  defp load_entries(user, vault_id) do
    row = Repo.with_tenant!(user.id, fn -> Repo.get(VaultIndexState, vault_id) end)

    case row do
      nil -> :none
      row -> with {:ok, snapshot} <- Crypto.decrypt_index_state(row, user), do: decode(snapshot)
    end
  end

  # NOT `:ok = Yex.apply_update(...)`. A snapshot that decrypts but is corrupt
  # raised a bare MatchError — burning all three attempts, landing in
  # `discarded`, carrying no vault_id — while the LESS corrupt case (would not
  # decrypt at all) was handled cleanly. That had the severity backwards.
  defp decode(snapshot) do
    doc = Yex.Doc.new()

    case Yex.apply_update(doc, snapshot) do
      :ok -> {:ok, doc |> Yex.Doc.get_map(CrdtIndexDoc.map_name()) |> Yex.Map.to_map()}
      _ -> {:error, :corrupt_snapshot}
    end
  end

  defp run(user, vault_id, entries) do
    {entries, duplicate_ids} = drop_duplicate_note_ids(entries, user.id, vault_id)

    # `scoped/2` is specced to take a struct OR a bare id and pattern-matches
    # `%{id: vault_id}`, so this bare map is a supported shape, not a stand-in
    # for a Vault we failed to load. That clause is the load-bearing contract:
    # anything added to the rename path that reads another vault field breaks
    # this at runtime, in a background job.
    vault = %{id: vault_id}

    case pass(
           user,
           vault,
           vault_id,
           entries,
           @max_passes,
           %{
             applied: 0,
             passes: 0,
             unknown_note: 0,
             malformed: 0,
             released: 0,
             release_skipped: 0,
             conflict: 0,
             stale: []
           }
         ) do
      {:error, reason} ->
        Logger.error(
          "vault index projection failed to read notes, will retry: " <>
            Metadata.safe_reason(reason),
          Metadata.with_category(:error, :sync, user_id: user.id, vault_id: vault_id)
        )

        {:error, reason}

      totals ->
        totals = release_stale_claims(user, vault_id, totals)
        report(vault_id, user.id, totals, duplicate_ids)
        :ok
    end
  end

  # Two entries naming the SAME note_id cannot both be satisfied, and applying
  # them in sequence makes the note oscillate: each pass moves it twice, minting
  # two tombstones, two seq bumps, two Qdrant repaths, two link rewrites and
  # four `delete`/`upsert` broadcasts to every connected device — forever, on
  # every checkpoint. Projection cannot pick a winner and must not guess, so
  # every entry for a duplicated id is dropped.
  defp drop_duplicate_note_ids(entries, user_id, vault_id) do
    duplicates =
      entries
      |> Enum.flat_map(fn
        {_path, %{"note_id" => id}} when is_binary(id) -> [id]
        _ -> []
      end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, count} -> count > 1 end)
      |> MapSet.new(fn {id, _count} -> id end)

    if MapSet.size(duplicates) > 0 do
      Logger.warning(
        "vault index projection dropped #{MapSet.size(duplicates)} note(s) claimed by " <>
          "more than one path",
        Metadata.with_category(:warning, :sync, user_id: user_id, vault_id: vault_id)
      )
    end

    kept =
      Enum.reject(entries, fn
        {_path, %{"note_id" => id}} -> MapSet.member?(duplicates, id)
        _ -> false
      end)

    {kept, MapSet.size(duplicates)}
  end

  # ONE metadata read per pass, not one full-row fetch + content decrypt per
  # entry: prod ran this ~640 times a day at ~900 ms each, almost all no-ops,
  # and only the path is ever read. Re-read per pass because the previous pass
  # moved rows. A DEK failure here used to read as "unknown note" per entry;
  # now it fails the job so Oban retries it.
  defp pass(user, vault, vault_id, entries, passes_left, acc) do
    ids = for {_path, %{"note_id" => id}} when is_binary(id) <- entries, do: id

    case Notes.get_note_meta_by_ids(user, vault, ids) do
      {:ok, notes} -> pass(user, vault, vault_id, entries, notes, passes_left, acc)
      {:error, _reason} = error -> error
    end
  end

  defp pass(user, vault, vault_id, entries, notes, passes_left, acc) do
    {outcome, retry, stale} =
      Enum.reduce(entries, {blank_outcome(), [], []}, fn entry, {o, retry, stale} ->
        case apply_entry(user, vault, vault_id, entry, notes) do
          :conflict = result -> {tally(o, result), [entry | retry], stale}
          {:stale, note_id} -> {o, retry, [note_id | stale]}
          result -> {tally(o, result), retry, stale}
        end
      end)

    # `unknown_note`/`malformed`/`stale` are terminal per entry — an entry
    # classified as one of them is never retried, so it can only ever appear in
    # THIS pass's outcome and must be summed in, not overwritten. `conflict` is
    # the opposite: it means "still stuck as of the pass that just ran", so the
    # latest value is the right one — an entry that conflicted in pass 1 and
    # then applied in pass 2 must stop counting as unresolved.
    acc = %{
      acc
      | applied: acc.applied + outcome.applied,
        unknown_note: acc.unknown_note + outcome.unknown_note,
        malformed: acc.malformed + outcome.malformed,
        stale: stale ++ acc.stale,
        conflict: outcome.conflict,
        passes: acc.passes + 1
    }

    # Re-run only the entries still stuck (`:conflict`), and only while a pass
    # BOTH made progress and left something stuck: that is the chain case, and
    # the next pass can place what was blocked. Zero progress means a swap or a
    # genuine disagreement, and another identical pass would only churn.
    #
    # Retrying the full `entries` list here used to re-run every already-
    # settled entry too, on every pass. Harmless for a :noop or :malformed, and
    # it would double-collect a stale id — re-running only what's still stuck
    # fixes that and every other redundant-reprocessing case at once. That is
    # also exactly why the counters above must accumulate: a terminal outcome
    # from an EARLIER pass would otherwise vanish the moment its entry drops out
    # of the retry list.
    if outcome.applied > 0 and outcome.conflict > 0 and passes_left > 1 do
      pass(user, vault, vault_id, Enum.reverse(retry), passes_left - 1, acc)
    else
      acc
    end
  end

  defp blank_outcome,
    do: %{applied: 0, noop: 0, conflict: 0, unknown_note: 0, malformed: 0}

  defp tally(outcome, key), do: Map.update!(outcome, key, &(&1 + 1))

  defp apply_entry(user, vault, vault_id, {path, %{"note_id" => note_id}}, notes)
       when is_binary(path) and is_binary(note_id) do
    case Map.fetch(notes, note_id) do
      {:ok, note} when is_binary(note.path) ->
        # This `==` is what makes the fixpoint loop terminate: without it every
        # already-correct entry counts as progress and the loop always runs to
        # @max_passes. rename_note/4 would no-op anyway — the LOOP needs to know.
        if note.path == path, do: :noop, else: rename(user, vault, note, path, vault_id)

      {:ok, _note} ->
        # A row whose path is not a binary is a decrypt anomaly, not a stale id.
        # It used to fall into the same silent branch as an unknown note.
        Logger.error(
          "vault index projection found a note with no readable path",
          Metadata.with_category(:error, :sync,
            user_id: user.id,
            vault_id: vault_id,
            note_id: note_id
          )
        )

        :malformed

      _ ->
        # The index names a note this vault does not have — wrong vault, soft
        # deleted, a create still in flight, or (#1550) a create that never
        # will land. NOT ours to invent: creating one would make projection a
        # writer of identity, which is the client's job. Age is the only signal
        # available to tell "still in flight" from "never coming" apart — see
        # `@stale_claim_grace_ms`.
        if stale_claim?(note_id) do
          # Collected, not released here: the whole run's stale ids go out as
          # ONE job after the loop (`release_stale_claims/3`).
          {:stale, note_id}
        else
          # Logged, unlike before. An index naming rows we do not have IS the
          # drift class #167 exists to eliminate; making it the one outcome
          # with no signal at all had it exactly backwards.
          Logger.warning(
            "vault index projection skipped an entry naming an unknown note",
            Metadata.with_category(:warning, :sync,
              user_id: user.id,
              vault_id: vault_id,
              note_id: note_id
            )
          )

          :unknown_note
        end
    end
  end

  defp apply_entry(user, _vault, vault_id, {_path, _other}, _notes) do
    # The path is NOT logged, in the message or the metadata. Interpolating it
    # into the message body would ship a plaintext note path to Loki and
    # CloudWatch in the clear — RedactFilter deliberately does not touch
    # `event.msg`. Putting it in metadata instead is safe (`:path` is a
    # sensitive key, so it gets scrubbed) but then carries no information, and
    # it reads as a banned `path:` arg key to NoPlaintextArgsTest's line lint.
    # The count is in telemetry; the value is client-controlled and unbounded.
    Logger.warning(
      "vault index projection skipped a malformed entry",
      Metadata.with_category(:warning, :sync, user_id: user.id, vault_id: vault_id)
    )

    :malformed
  end

  # UUIDv7 encodes its own mint time, so an entry's age needs no extra state.
  # `false` for anything that isn't a v7 UUID — never guess an id we can't
  # read, and a v4 id (the shape a pre-#431 client or a test double might send)
  # must fall through to the existing unknown-note path unaffected.
  defp stale_claim?(note_id) do
    case Ecto.UUID.dump(note_id) do
      {:ok, <<ms::48, 7::4, _::76>>} ->
        System.system_time(:millisecond) - ms > @stale_claim_grace_ms

      _ ->
        false
    end
  end

  # Async and uniform with every other release (`ReleaseIndexEntries`) — never
  # inline, so a DEK rotation in progress retries the release instead of
  # losing it. Nothing else ever releases this claim: a create that never
  # lands is not a delete, so `Notes.delete_note`'s release never fires for it.
  #
  # ONE job per run, carrying every stale id, and ONE summary log line. The
  # 2026-10-23 storm (vault f4cd93e6, a first sync whose creates died in a DB
  # pool exhaustion) enqueued one job and logged one line PER id: 4,792 jobs,
  # then 14,437+, each its own notes read, index-room edit (a full map copy)
  # and encrypted tail append. It pinned a web task, then a worker.
  #
  # The job works through its ids `ReleaseIndexEntries.chunk_size/0` at a
  # time, one link of a chain per chunk, each link one index-room change. One
  # link runs at a time, so a storm holds one queue slot, not all of them. The
  # args stay bounded by the index itself: every id here is an entry in a
  # snapshot capped at 16 MB (`CrdtIndexPersistence`), at ~40 B per id.
  # `ReleaseIndexEntries` owns the chunk size and the chain.
  #
  # Backoff for re-claims: the grace is measured from the UUIDv7 MINT time, not
  # from when the claim was written, so a client that re-claims an id older
  # than an hour is "stale" again immediately and would be released on every
  # checkpoint. An id is remembered (`@released_cache`) once its release is
  # ENQUEUED, never before, so an enqueue failure cannot suppress the retry;
  # a job that later fails is retried by Oban itself (`max_attempts: 5`), and
  # one that is discarded gets a fresh release once the window passes.
  defp release_stale_claims(_user, _vault_id, %{stale: []} = totals), do: totals

  defp release_stale_claims(user, vault_id, %{stale: stale} = totals) do
    {repeat, fresh} = Enum.split_with(stale, &recently_released?(vault_id, &1))

    case Enqueue.enqueue(
           ReleaseIndexEntries.new_for(user.id, vault_id, fresh),
           "release_index_entries"
         ) do
      {:ok, _job_or_skipped} ->
        Enum.each(fresh, &Cache.put(@released_cache, {vault_id, &1}, true))

        Logger.warning(
          "vault index projection released #{length(fresh)} stale claim(s) for notes that " <>
            "never arrived, skipped #{length(repeat)} released within the last hour",
          Metadata.with_category(:warning, :sync,
            user_id: user.id,
            vault_id: vault_id,
            note_ids: Enum.take(fresh ++ repeat, @log_sample)
          )
        )

        %{totals | released: length(fresh), release_skipped: length(repeat)}

      {:error, reason} ->
        # Enqueue.enqueue/2 already logged its own generic failure line, but
        # without a vault_id. Reporting these as released would tell a
        # dashboard the claims are resolved when the job to resolve them was
        # never queued, so they count as unresolved and the next run retries.
        Logger.warning(
          "vault index projection could not enqueue a release of #{length(fresh)} stale " <>
            "claim(s): #{Metadata.safe_reason(reason)}",
          Metadata.with_category(:warning, :sync,
            user_id: user.id,
            vault_id: vault_id,
            note_ids: Enum.take(fresh, @log_sample)
          )
        )

        %{
          totals
          | unknown_note: totals.unknown_note + length(fresh),
            release_skipped: length(repeat)
        }
    end
  end

  defp recently_released?(vault_id, note_id),
    do: match?({:ok, _}, Cache.get(@released_cache, {vault_id, note_id}))

  defp rename(user, vault, note, path, vault_id) do
    # `note_id:`: `note.path` is from this pass's snapshot. If the note moved
    # and another note took that path since, renaming by path alone would move
    # the other note. Pinned to the id, that race is a :not_found instead.
    case Notes.rename_note(user, vault, note.path, path, index: :skip, note_id: note.id) do
      {:ok, _note} ->
        :applied

      {:error, reason} ->
        # :conflict means the target path is held by a DIFFERENT note — the
        # index and the rows disagree, and the client owns identity.
        # :not_found means the row moved between the id lookup and this call
        # (TOCTOU); the next run sees the new state.
        Logger.warning(
          "vault index projection could not move a note: #{Metadata.safe_reason(reason)}",
          Metadata.with_category(:warning, :sync,
            user_id: user.id,
            vault_id: vault_id,
            note_id: note.id
          )
        )

        :conflict
    end
  end

  # One event per run carrying what actually happened. Without it an empty index
  # and an index where all 40 entries failed to apply are byte-identical to
  # logs, metrics, Oban and Sentry simultaneously.
  defp report(
         vault_id,
         user_id,
         %{
           applied: applied,
           passes: passes,
           conflict: conflict,
           unknown_note: unknown_note,
           malformed: malformed,
           released: released,
           release_skipped: release_skipped
         },
         duplicates
       ) do
    unresolved = conflict + unknown_note + malformed + duplicates

    :telemetry.execute(
      @event,
      %{
        applied: applied,
        unresolved: unresolved,
        conflict: conflict,
        unknown_note: unknown_note,
        malformed: malformed,
        duplicate_note_ids: duplicates,
        released: released,
        release_skipped: release_skipped,
        passes: passes
      },
      %{phase: if(unresolved == 0, do: :converged, else: :unresolved)}
    )

    if unresolved > 0 do
      Logger.warning(
        "vault index projection did not converge: applied=#{applied} " <>
          "unresolved=#{unresolved} passes=#{passes}",
        Metadata.with_category(:warning, :sync, user_id: user_id, vault_id: vault_id)
      )
    end

    :ok
  end

  # Every measurement a PromEx metric reads off @event, as 0: Peep records 1
  # for an ABSENT key, so a missing `released` reported one released claim per
  # no-op run.
  defp emit(phase) do
    :telemetry.execute(
      @event,
      %{applied: 0, unresolved: 0, released: 0, release_skipped: 0, passes: 0},
      %{phase: phase}
    )

    :ok
  end
end
