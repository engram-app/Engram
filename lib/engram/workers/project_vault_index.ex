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

  alias Engram.{Accounts, Crypto, Notes, Repo}
  alias Engram.Crypto.RotationGate
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtIndexDoc, VaultIndexState}

  require Logger

  # Bounds the fixpoint loop. A chain of N renames needs at most N passes, so a
  # chain longer than this is left PARTIALLY applied and resumes on the next
  # checkpoint's run — which is legitimate, and is the same property the
  # per-vault `unique` window relies on. The cap is here so a swap (which cannot
  # converge at all) stops churning, not because 6 rounds means failure.
  @max_passes 5

  @event [:engram, :crdt, :index_projection]

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
        # key the sweep is moving underneath it (#1341).
        case RotationGate.check_user(user) do
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
    {:ok, row} = Repo.with_tenant(user.id, fn -> Repo.get(VaultIndexState, vault_id) end)

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

    totals =
      pass(user, vault, vault_id, entries, @max_passes, %{applied: 0, passes: 0, last: nil})

    report(vault_id, user.id, totals, duplicate_ids)
    :ok
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

  defp pass(user, vault, vault_id, entries, passes_left, acc) do
    outcome =
      Enum.reduce(entries, blank_outcome(), fn entry, o ->
        tally(o, apply_entry(user, vault, vault_id, entry))
      end)

    acc = %{acc | applied: acc.applied + outcome.applied, passes: acc.passes + 1, last: outcome}

    # Re-run only while a pass BOTH made progress and left something stuck: that
    # is the chain case, and the next pass can place what was blocked. Zero
    # progress means a swap or a genuine disagreement, and another identical
    # pass would only churn.
    if outcome.applied > 0 and outcome.conflict > 0 and passes_left > 1 do
      pass(user, vault, vault_id, entries, passes_left - 1, acc)
    else
      acc
    end
  end

  defp blank_outcome, do: %{applied: 0, noop: 0, conflict: 0, unknown_note: 0, malformed: 0}

  defp tally(outcome, key), do: Map.update!(outcome, key, &(&1 + 1))

  defp apply_entry(user, vault, vault_id, {path, %{"note_id" => note_id}})
       when is_binary(path) and is_binary(note_id) do
    case Notes.get_note_by_id(user, vault, note_id) do
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
        # deleted, or a stale id. NOT ours to invent: creating one would make
        # projection a writer of identity, which is the client's job.
        #
        # Logged, unlike before. An index naming rows we do not have IS the
        # drift class #167 exists to eliminate; making it the one outcome with
        # no signal at all had it exactly backwards.
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

  defp apply_entry(user, _vault, vault_id, {_path, _other}) do
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

  defp rename(user, vault, note, path, vault_id) do
    case Notes.rename_note(user, vault, note.path, path, index: :skip) do
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
  defp report(vault_id, user_id, %{applied: applied, passes: passes, last: last}, duplicates) do
    unresolved = last.conflict + last.unknown_note + last.malformed + duplicates

    :telemetry.execute(
      @event,
      %{
        applied: applied,
        unresolved: unresolved,
        conflict: last.conflict,
        unknown_note: last.unknown_note,
        malformed: last.malformed,
        duplicate_note_ids: duplicates,
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

  defp emit(phase) do
    :telemetry.execute(@event, %{applied: 0, unresolved: 0, passes: 0}, %{phase: phase})
    :ok
  end
end
