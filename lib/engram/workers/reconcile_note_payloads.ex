defmodule Engram.Workers.ReconcileNotePayloads do
  @moduledoc """
  Heals Qdrant points whose note-level payload (the filter HMACs and dates,
  `Engram.Indexing.expected_note_payload/1`) no longer matches their note's
  row, one user per chain. Run by the `NotePayloadStamps` data migration and
  enqueued by every DEK rotation right after its flip.

  The case it exists for: every filter HMAC derives from the DEK. A rotation
  rekeys the rows, and the points follow here, outside the rotation (no
  Qdrant call may sit before the rotation's flip). A rotation before this
  worker existed left the points on the old key for good.

  Two kinds of job, each its own unique slot (`Engram.Jobs`, keys
  `[:user_id, :mode]`; the fleet job carries no `user_id`, so its slot is
  its mode alone):

    * the HEAL (`mode: "heal"`, the default of `new/2`): main's path and
      selection, a note whose `payload_hash` is NULL (below). Queued by a
      DEK rotation, FileTimes, the Drain and the ledger. It asks no `n`
      gate, reads nothing for `n`, writes no `n` on its own and never stamps
      the payload version, so nothing about the backfill can hold, fail or
      merge into it;
    * the `n` BACKFILL, ONE job for the whole fleet (`mode: "n_fleet"`,
      one unique slot: its args carry no `user_id`): payload version 6
      means "every v5 point carries `n`, its note row id" (immutable chunk
      index, Engram#2263). Queued by the ledger whenever a pass finds a
      user behind. Every gate runs FIRST, before any read: the kill switch
      `:payload_backfill` (off: `{:cancel, :paused}`, no snooze; the ledger
      re-adds it once the switch is back on), `Engram.Rebuild.qdrant_pace/1`
      (disk at the 75% gate, optimizer and queue backlog; a growing backoff
      on its own count, meta `"gated"`), then a free peek of the fleet-wide
      bucket `:payload_backfill_points_per_min` (default 500; a spent window
      re-queues to its edge). It walks the users in id order from a
      persisted cursor (`Engram.Maintenance.Cursor`), each user's notes in
      fixed id windows, selecting only stamped notes behind the version;
      each v5 point without `n` gets `%{"n" => note}` MERGED (never a key
      deleted), in pages capped at what the window has left and charged
      with their real size. No DEK, no decrypt, no upsert, no embedder call.
      Then the notes are stamped with the version (compare-and-set on the
      hash), not one holding legacy v3 points (they never get `n`, and have
      no `u` for an `n` search). A held window stores the cursor and the job
      queues itself again at the window's edge: one wake a window for the
      fleet, never one per user. A lap that reaches the last user ends the
      job; the hourly ledger queues it again while anyone is behind. A
      re-run rewrites nothing: stamped notes are not selected again,
      written points are skipped. A per-user `mode: "n"` job (0.77.0)
      cancels itself on wake and queues the fleet job.

  A note is checked while its `payload_hash` is NULL. Its points are READ
  (payload keys only); if every one already holds the expected payload the
  row is just stamped, otherwise the drifted ones are rewritten with
  `set_payload` (never an upsert: vectors and text are untouched, no
  embedder call) and its `keyword_version` is cleared, because the sparse
  vectors are keyed on the same filter key. The stamp is a compare-and-set,
  so a concurrent index wins. A note whose points are all gone is stamped
  too: the next index re-creates them.

  Both layouts. A v3 point gets `expected_note_payload/1` merged in; a v5
  point (#2087's short-key layout) gets `expected_v5_payload/2`, built from
  the decrypted note as a pass builds it, and REPLACED (`overwrite_payload`).
  A v5 note whose ciphertext fails AEAD under the current DEK
  (`{:error, :decrypt_failed}`; any other error is transient and fails the
  job) cannot be healed: it is counted
  (`skipped_v5`) and marked with `undecryptable_stamp/0` in `payload_hash`,
  so the daily re-check does not requeue its user forever. Never deleted;
  the stamp matches no real hash, so the note's next index pass refreshes
  its points and stamps the real one.

  Every note row is read fresh per batch, so an edit that commits after a
  rotation's flip is healed with its own keys, and one whose index already
  re-stamped `payload_hash` is not selected at all.

  Rate-limited: one batch of 200 notes costs one scroll per 2048 points plus
  a `set_payload` per drifted note, with a pause between batches, on the
  single-slot `crdt_backfill` lane. Qdrant refusals and unapplied waits
  snooze; a 4xx (a request Qdrant refuses on every attempt) cancels the job
  once, logged with its status, and the hourly re-check retries the user. Each hop logs its counts and emits
  `[:engram, :indexing, :payload_reconcile]` per outcome
  (`Engram.PromEx.Indexing`).
  """
  # One chain per user, as `BackfillLinkKeys`: `:executing` is not a unique
  # state, so a job can insert its own successor.
  use Oban.Worker,
    queue: :crdt_backfill,
    priority: 3,
    max_attempts: 5,
    unique: Engram.Jobs.unique(__MODULE__)

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Backfill.IdWindows
  alias Engram.Backfill.TenantScan
  alias Engram.Cluster.Readiness
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Indexing
  alias Engram.Indexing.PayloadV6
  alias Engram.Jobs
  alias Engram.Logger.Metadata
  alias Engram.Maintenance.Cursor
  alias Engram.Notes.{Chunk, Note, NoteBody, NoteIndexState}
  alias Engram.Rebuild
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.Vector.FilterId
  alias Engram.Vector.PayloadKeys
  alias Engram.Vector.Qdrant
  alias Engram.Workers.RefreshKeywordVectors
  alias EngramWeb.RateLimiter

  require Logger

  @batch_size 200
  # Ops per `set_payloads` request (one point per op).
  @refresh_page 256
  @event [:engram, :indexing, :payload_reconcile]
  @cancelled_event [:engram, :indexing, :payload_reconcile_cancelled]
  @zero %{checked: 0, drifted: 0, rewritten: 0, skipped_v5: 0, n_points: 0}
  @budget_ms 30_000
  # Between batches, so a large vault never saturates Qdrant.
  @pause_ms 200

  # The payload version from which every v5 point carries `n`.
  @n_version 6
  @n_key PayloadKeys.short(:note)
  # The `n` backfill's fleet-wide token bucket (`:payload_backfill_points_per_min`).
  @n_bucket "payload_backfill_points"
  @n_window_ms 60_000
  @n_per_min 500
  # An `n` job's Oban priority: behind the heal's (`priority: 3` above).
  @n_priority 5
  # Where `requeue_unbackfilled/0`'s walk resumes.
  @requeue_cursor "payload_n_requeue"
  # The fleet `n` job: its mode, and where its users walk resumes.
  @fleet_mode "n_fleet"
  @fleet_cursor "payload_n_fleet"
  # Users read per page of the fleet walk (`users` is not a tenant table).
  @user_page 100

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @doc """
  A job for `args`, as `Oban.Worker.new/2`, with `"mode"` defaulted to
  `"heal"`. The unique keys are `[:user_id, :mode]`, and Oban compares only
  the keys a NEW job's args carry: a heal without a mode would match a
  queued `n` backfill (`mode: "n"`) and be dropped into it. Every caller
  (DEK rotation, FileTimes, the Drain, the ledger) goes through here.
  """
  @impl Oban.Worker
  def new(args, opts) when is_map(args) and is_list(opts) do
    args = Map.put_new(args, "mode", "heal")

    # `n` jobs sort behind heals on the one `crdt_backfill` lane, so a heal
    # is never queued behind an `n` wake.
    opts =
      if args["mode"] in ["n", @fleet_mode],
        do: Keyword.put_new(opts, :priority, @n_priority),
        else: opts

    super(args, opts)
  end

  @impl Oban.Worker
  # The `n` backfill: one job for the fleet (`mode: "n_fleet"`, its own
  # unique slot), never mixed with a heal.
  def perform(%Oban.Job{args: %{"mode" => @fleet_mode}} = job) do
    case n_gates(job) do
      :ok -> n_fleet()
      :paused -> {:cancel, :paused}
      :yield -> yield(job)
      {:snooze, wait} -> requeue_fleet(wait, gated(job) + 1)
      :spent -> requeue_fleet(edge_snooze(), 0)
    end
  end

  # A per-user `n` job queued by 0.77.0: the fleet job owns its work now.
  def perform(%Oban.Job{args: %{"mode" => "n"}}) do
    :ok = ensure_fleet()
    {:cancel, :superseded}
  end

  # The heal (a NULL `payload_hash`: DEK rotation, FileTimes, a lost stamp
  # race, the Drain): main's path and selection, with no `n` gate, no `n`
  # read and no `n` write, so nothing about the backfill can hold or fail it.
  def perform(%Oban.Job{args: %{"user_id" => user_id} = args} = job) do
    with %User{} = user <- Repo.get(User, user_id),
         :ok <- RotationGate.check_user(user) do
      deadline = System.monotonic_time(:millisecond) + @budget_ms
      {result, counts} = heal(user, args["after"], deadline, @zero)
      report(user_id, counts)

      case result do
        :done ->
          :ok

        {:more, after_id} ->
          {:ok, _} = Oban.insert(new(%{"user_id" => user_id, "after" => after_id}))
          :ok

        other ->
          other
      end
    else
      nil -> :ok
      {:error, :rotation_in_progress} -> locked_snooze(user_id, job)
    end
  end

  # A crashed rotation keeps its lock on purpose (an operator must clear it),
  # and the heal must not write under it, so it keeps snoozing. After an
  # hour of that, one warning per job.
  @lock_warn_after 60
  defp locked_snooze(user_id, %Oban.Job{meta: meta}) do
    if (meta["snoozed"] || 0) == @lock_warn_after do
      Logger.warning(
        "note payload reconcile: rotation lock held for an hour, still waiting",
        Metadata.with_category(:warning, :oban, user_id: user_id)
      )
    end

    {:snooze, 60}
  end

  @doc """
  One id window of the ledger's walk (`IdWindows.heal_pass/4`,
  `NotePayloadStamps`): queues a heal for the users whose notes in `ids`
  are unstamped, and the one fleet `n` job (`enqueue_n/1`) when any user's
  stamped notes are behind the version. Returns `{users queued, false}`; any queued makes the
  walk dirty.
  """
  def queue_window(ids, %{repo: repo}) do
    users = fn query ->
      query
      |> select([note: n], n.user_id)
      |> distinct(true)
      |> IdWindows.by_id(ids)
      |> repo.all()
    end

    healed = TenantScan.enqueue_users(__MODULE__, users.(unstamped()))
    {healed + enqueue_n(users.(n_behind())), false}
  end

  @doc """
  The ledger's enqueue for users behind the version: the one fleet job
  (`ensure_fleet/0`) when any are, never a job per user. Returns how many
  users were behind.
  """
  @spec enqueue_n([Ecto.UUID.t()]) :: non_neg_integer()
  def enqueue_n([]), do: 0

  def enqueue_n(user_ids) do
    :ok = ensure_fleet()
    length(user_ids)
  end

  @doc """
  Queues the fleet `n` job unless one is pending (its unique slot) or
  executing (it queues its own successor, so `executing` cannot be a unique
  state).
  """
  @spec ensure_fleet() :: :ok
  def ensure_fleet, do: if(fleet_job?(["executing"]), do: :ok, else: insert_fleet([]))

  # The self re-queue. Oban's unique insert answers a conflict WITHOUT
  # inserting when another insert holds its advisory lock, so a conflict is
  # checked: a fleet job must be pending. If none is, the chain is lost until
  # the next hourly ledger pass re-adds it; logged so that shows.
  defp requeue_fleet(wait, gated) do
    insert_fleet(schedule_in: wait, meta: %{"gated" => gated})
  end

  defp insert_fleet(opts) do
    {:ok, job} = insert_fun().(new(%{"mode" => @fleet_mode}, opts))

    if job.conflict? and not fleet_job?(Jobs.pending_states()) do
      Logger.warning(
        "note payload reconcile: fleet re-queue lost to a unique-insert race, the ledger re-adds it",
        Metadata.with_category(:warning, :oban, [])
      )
    end

    :ok
  end

  # A fleet job in `states` (narrowed by `scope`, a query function).
  defp fleet_job?(states, scope \\ & &1) do
    from(j in Oban.Job,
      where: j.worker == ^inspect(__MODULE__) and j.state in ^states,
      where: fragment("?->>'mode' = ?", j.args, ^@fleet_mode)
    )
    |> scope.()
    |> Repo.exists?()
  end

  # Tests stand in for Oban's busy-lock conflict here.
  defp insert_fun, do: Application.get_env(:engram, :reconcile_n_insert_fun, &Oban.insert/1)

  @doc "True while the user has an unstamped indexed note (the worker's own selection predicate)."
  @spec unstamped_rows?(Ecto.UUID.t()) :: boolean()
  def unstamped_rows?(user_id) do
    {:ok, any} =
      Repo.with_tenant(user_id, fn ->
        Repo.exists?(where(unstamped(), [n], n.user_id == ^user_id))
      end)

    any
  end

  # The heal's selection and the drain's confirm, one definition: an
  # unstamped indexed note (main's predicate).
  defp unstamped, do: where(indexed_notes(), [note: n], is_nil(n.payload_hash))

  # The `n` backfill's selection: a stamped indexed note whose points were
  # written with an older payload version. An unstamped one is the heal's.
  defp n_behind,
    do: where(indexed_notes(), [note: n], not is_nil(n.payload_hash)) |> where(^stale())

  # Notes with at least one Qdrant point, as `:note`.
  defp indexed_notes do
    from(n in Note,
      as: :note,
      where:
        n.kind == "note" and
          exists(
            from(c in Chunk,
              where: c.note_id == parent_as(:note).id and not is_nil(c.qdrant_point_id)
            )
          )
    )
  end

  # The note's points were written with an older payload version.
  defp stale do
    version = PayloadV6.version()
    base = PayloadV6.baseline()

    dynamic(
      exists(
        from(s in NoteIndexState,
          where:
            s.note_id == parent_as(:note).id and coalesce(s.payload_version, ^base) < ^version
        )
      )
    )
  end

  defp heal(%User{id: user_id} = user, after_id, deadline, counts) do
    {notes, points} = batch(user_id, after_id)

    cond do
      notes == [] ->
        {:done, counts}

      System.monotonic_time(:millisecond) > deadline ->
        {{:more, after_id}, counts}

      true ->
        with {:ok, stored} <- read_payloads(user_id, points |> Map.values() |> List.flatten()),
             # Per batch, after the read and before any write: a rotation
             # that started since would have its fresh keys overwritten.
             :ok <- RotationGate.check(user_id),
             {:ok, counts} <- heal_unstamped(user, notes, points, stored, counts) do
          if length(notes) < @batch_size do
            {:done, counts}
          else
            Process.sleep(@pause_ms)
            heal(user, List.last(notes).id, deadline, counts)
          end
        else
          {:error, reason, counts} -> {answer(user_id, reason), counts}
          {:error, reason} -> {answer(user_id, reason), counts}
        end
    end
  end

  # One line per failed hop with the reason's class (status and tag, never a
  # body, an id list or note content), then the Oban answer.
  defp answer(user_id, reason) do
    result = qdrant_answer(reason)

    # The hourly re-check retries a cancelled user, so a refusal no fix has
    # cleared cancels once an hour forever: this counter is what alerts on it.
    if match?({:cancel, _}, result),
      do: :telemetry.execute(@cancelled_event, %{count: 1}, %{http_status: http_status(reason)})

    if match?({tag, _} when tag in [:error, :cancel], result) do
      Logger.warning(
        "note payload reconcile failed",
        Metadata.with_category(:warning, :oban,
          user_id: user_id,
          reason_label: Metadata.safe_reason(reason),
          result: elem(result, 0)
        )
      )
    end

    result
  end

  # As every other Qdrant writer: refusal and an unapplied wait are snoozes,
  # not attempts (five of those and the job is discarded into the same
  # pressure). A 4xx Qdrant refusal (a filter on an unindexed key, a bad
  # request shape) fails the same way on every attempt: cancel once, the
  # hourly re-check retries the user after a fix ships (#2138). A 5xx or a
  # transport error (timeout) keeps Oban's backoff.
  defp qdrant_answer(:rotation_in_progress), do: {:snooze, 60}
  defp qdrant_answer(:user_not_found), do: :ok
  defp qdrant_answer(:qdrant_backpressure), do: Qdrant.backpressure_snooze(:refused)
  defp qdrant_answer(:qdrant_wait_timeout), do: Qdrant.wait_timeout_snooze()

  defp qdrant_answer(reason) do
    case http_status(reason) do
      status when status in [429, 503, 507] -> Qdrant.backpressure_snooze(:refused)
      status when status in 400..499 -> {:cancel, reason}
      _ -> {:error, reason}
    end
  end

  # `scroll/2` and the payload writes (`write_error/2`) tag a refusal differently.
  defp http_status({:qdrant_scroll, status, _body}) when is_integer(status), do: status
  defp http_status({status, _body}) when is_integer(status), do: status
  defp http_status(_reason), do: nil

  defp batch(user_id, after_id) do
    query =
      from(n in unstamped(), where: n.user_id == ^user_id, order_by: n.id, limit: @batch_size)

    query = if after_id, do: where(query, [n], n.id > ^after_id), else: query

    {:ok, result} =
      Repo.with_tenant(user_id, fn ->
        notes = Repo.all(NoteBody.select_note(query))
        ids = Enum.map(notes, & &1.id)

        points =
          from(c in Chunk,
            where: c.note_id in ^ids and not is_nil(c.qdrant_point_id),
            select: {c.note_id, c.qdrant_point_id}
          )
          |> Repo.all()
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

        {notes, points}
      end)

    result
  end

  # `%{point_id => payload}` for the points that exist, payload keys only.
  defp read_payloads(user_id, ids) do
    keys =
      Enum.uniq(
        v5_keys() ++
          (Indexing.expected_note_payload(%Note{}) |> Map.keys() |> Enum.map(&to_string/1))
      )

    ids
    |> Enum.chunk_every(Qdrant.max_ids())
    |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, acc} ->
      case Qdrant.scroll(Qdrant.collection_name(),
             # The tenant condition every reader uses: `user_id` OR `u` while
             # legacy filters are on, `u` alone once they are off. Never a
             # hand-built condition: strict mode answers 400 to a filter on
             # an unindexed key (#2138). Both layouts still come back.
             filter: %{must: [%{has_id: chunk}, Qdrant.match_filter(:user, user_id)]},
             with_payload: keys,
             limit: length(chunk)
           ) do
        {:ok, %{points: points}} ->
          {:cont, {:ok, Enum.into(points, acc, &{&1["id"], &1["payload"] || %{}})}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  @undecryptable "undecryptable"

  @doc """
  The `payload_hash` of a note the heal could not decrypt. Not a SHA-256
  (a real stamp is 32 bytes), so it never vouches for any payload.
  """
  def undecryptable_stamp, do: @undecryptable

  # CAS on the row as read (an edit since then re-indexes and stamps it) and
  # on the user's DEK version: a rotation flip in between NULLs every stamp,
  # and the row may open under the new DEK.
  defp mark_undecryptable(note, user) do
    {:ok, {_, _}} =
      Repo.with_tenant(note.user_id, fn ->
        same_content =
          if note.content_hash,
            do: dynamic([n], n.content_hash == ^note.content_hash),
            else: dynamic([n], is_nil(n.content_hash))

        from(n in Note,
          where: n.kind == "note" and n.id == ^note.id and is_nil(n.payload_hash),
          where: ^same_content,
          where: exists(same_dek(user))
        )
        |> Repo.update_all(set: [payload_hash: @undecryptable])
      end)

    :ok
  end

  defp same_dek(%User{id: id, dek_version: nil}),
    do: from(u in User, where: u.id == ^id and is_nil(u.dek_version), select: 1)

  defp same_dek(%User{id: id, dek_version: v}),
    do: from(u in User, where: u.id == ^id and u.dek_version == ^v, select: 1)

  defp legacy_points?(note, points, stored),
    do: Enum.any?(Map.get(points, note.id, []), &(stored[&1] && not v5?(stored[&1])))

  defp heal_unstamped(user, notes, points, stored, counts) do
    Enum.reduce_while(notes, {:ok, counts}, fn note, {:ok, counts} ->
      present = for id <- Map.get(points, note.id, []), Map.has_key?(stored, id), do: id
      {v5_ids, v3_ids} = Enum.split_with(present, &v5?(stored[&1]))
      counts = bump(counts, :checked)

      case plan_note(user, note, v5_ids, v3_ids, stored) do
        {:ok, writes, payload} ->
          # The heal never stamps the payload version: its writes carry `n`
          # (`PayloadV5.build/2`) but a point it did not rewrite may lack it,
          # so only the `n` backfill vouches for the version.
          heal_note(note, payload, writes, counts, false)

        :skip ->
          mark_undecryptable(note, user)
          {:cont, {:ok, bump(counts, :skipped_v5)}}

        {:error, reason} ->
          {:halt, {:error, reason, counts}}
      end
    end)
  end

  # A note stamped but behind the version: the `n` backfill (`backfill_n/5`)
  # already wrote what the version adds, and its hash vouches for the rest,
  # so it is only stamped. No decrypt, no drift check. Only while the row
  # still holds the hash read: a previous-release node that re-upserted the
  # note since (without `n`) changed or NULLed it, and must not be vouched for.
  # Compared on `PayloadKeys.refresh_keys/0` only: the identity keys (`u`,
  # `v`, `n`) never change for a point, and a release that does not write
  # `n` must not see a point holding it as drifted.
  defp drifted?(point, want) do
    keys = PayloadKeys.refresh_keys()
    Map.take(point, keys) != Map.take(want, keys)
  end

  # v5 points (`u` set) without `n`, fleet-wide.
  defp missing_n_filter,
    do: %{must: [%{is_empty: %{key: @n_key}}], must_not: [%{is_empty: %{key: "u"}}]}

  @doc """
  True when every node of the cluster runs a release that writes `n`: the
  one fleet gate, `Engram.Cluster.Readiness.peers_report/4`, over
  `PayloadV6.version/0 >= 6` (an older release answers 5, or lacks the
  function). Every expected member must be connected, so a just-booted node
  not yet joined to the old ones fails closed. Options as `peers_report/4`.
  """
  @spec cluster_writes_n?(keyword()) :: boolean()
  def cluster_writes_n?(opts \\ []),
    do: Readiness.peers_report(PayloadV6, :version, @n_version, opts) == :ok

  # Every v5 point of the batch's notes the read shows without `n` gets it,
  # merged, in paced pages. A point missing from the read is not written: a
  # note whose points are gone is re-created by its next index.
  # Every gate, before any read: the kill switch, the Qdrant gate (cached),
  # then a free peek of the bucket. A gated job reads nothing from Postgres
  # or Qdrant. The Qdrant gate backs off on its own count (meta `"gated"`),
  # not on Oban's `"snoozed"`, so edge waits never push it to the ceiling.
  # A second fleet job (the unique race, a budget re-queue fetched on
  # another node before its parent acked) never runs beside the first: the
  # higher id yields to a lower-id one executing, by SNOOZING, so it stays
  # the pending chain if the other dies (a job orphaned in `executing`
  # until Lifeline rescues it). Never a cancel: two that each saw the other
  # executing would both drop out. Two pending ones need no check: they
  # run one after the other, and the first one's re-queue conflicts with
  # the second, so one stays pending.
  defp n_gates(job) do
    cond do
      not backfill_enabled?() -> :paused
      lower_fleet_executing?(job) -> :yield
      (pace = Rebuild.qdrant_pace(%{job | meta: %{"snoozed" => gated(job)}})) != :ok -> pace
      RateLimiter.peek(@n_bucket, @n_window_ms, n_per_min()) == 0 -> :spent
      true -> :ok
    end
  end

  defp gated(%Oban.Job{meta: meta}), do: Map.get(meta || %{}, "gated", 0)

  @yield_s 60

  defp yield(%Oban.Job{id: id}) do
    Logger.debug(
      "note payload reconcile: fleet job yields to a lower-id one executing",
      Metadata.with_category(:debug, :oban, job_id: id)
    )

    {:snooze, @yield_s}
  end

  defp lower_fleet_executing?(%Oban.Job{id: nil}), do: fleet_job?(["executing"])

  defp lower_fleet_executing?(%Oban.Job{id: id}),
    do: fleet_job?(["executing"], &where(&1, [j], j.id < ^id))

  # One run of the fleet job: users in id order from the stored cursor, each
  # walked (`n_walk/3`) until the bucket, the budget or the switch stops it.
  # The cursor is stored where it stopped; a lap that reached the last user
  # resets it and ends the job.
  defp n_fleet do
    deadline = System.monotonic_time(:millisecond) + @budget_ms

    {result, _locked} = fleet_walk(Cursor.get(@fleet_cursor), deadline, 0)

    case result do
      :lap ->
        Cursor.reset(@fleet_cursor)

      {stop, cursor} ->
        :ok = Cursor.put(@fleet_cursor, cursor)
        fleet_answer(stop)
    end
  end

  defp fleet_answer(:budget), do: requeue_fleet(0, 0)
  defp fleet_answer(:held), do: requeue_fleet(edge_snooze(), 0)
  defp fleet_answer(:paused), do: {:cancel, :paused}
  defp fleet_answer({:snooze, wait}), do: requeue_fleet(wait, 0)
  defp fleet_answer(other), do: other

  # Cursor shapes: nil (the lap's start), `%{"user" => id, "after" => note}`
  # (resume that user after that note), `%{"past" => id}` (the next user).
  # With how many rotation-locked users it passed over.
  defp fleet_walk(cursor, deadline, locked) do
    case next_users(cursor) do
      [] ->
        {:lap, locked}

      users ->
        case Enum.reduce_while(users, {cursor, locked}, &fleet_user(&1, &2, deadline)) do
          {:stop, stop, at, locked} -> {{stop, at}, locked}
          {cursor, locked} -> fleet_walk(cursor, deadline, locked)
        end
    end
  end

  defp next_users(cursor) do
    query = from(u in User, order_by: u.id, limit: @user_page)

    case cursor do
      %{"user" => id} -> where(query, [u], u.id >= ^id)
      %{"past" => id} -> where(query, [u], u.id > ^id)
      _ -> query
    end
    |> Repo.all()
  end

  # A user under a rotation lock is passed over: the ledger finds it behind
  # again, and the next lap writes it. A 4xx refusal is logged and counted
  # once by `answer/2` (the `payload_reconcile_cancelled` alert), and the
  # walk carries on with the next user, so one user's refusal never holds
  # the fleet.
  defp fleet_user(%User{id: id} = user, {cursor, locked}, deadline) do
    after_id = if match?(%{"user" => ^id}, cursor), do: cursor["after"]
    past = %{"past" => id}

    cond do
      # A user with no notes reads no window, so the budget is checked here too.
      System.monotonic_time(:millisecond) > deadline ->
        {:halt, {:stop, :budget, %{"user" => id, "after" => after_id}, locked}}

      RotationGate.check_user(user) != :ok ->
        {:cont, {past, locked + 1}}

      # A done user costs this one probe, not a walk of its notes.
      not n_behind?(id) ->
        {:cont, {past, locked}}

      true ->
        case walk_user(user, after_id, deadline) do
          :next -> {:cont, {past, locked}}
          {stop, at} -> {:halt, {:stop, stop, at, locked}}
        end
    end
  end

  # One EXISTS over the user's notes (`n_behind/0`, the walk's own
  # selection), on the notes user index; it stops at the first note behind.
  # ponytail: a done user's probe still reads its index entries once; a
  # partial index on `note_index_state` (user_id) WHERE behind is the upgrade
  # if done users with large vaults ever dominate a lap.
  defp n_behind?(user_id) do
    {:ok, any} =
      Repo.with_tenant(user_id, fn ->
        Repo.exists?(where(n_behind(), [note: n], n.user_id == ^user_id))
      end)

    any
  end

  # `:next` (the user is done, gone or refused with a 4xx), or `{stop,
  # cursor}` to resume it from.
  defp walk_user(%User{id: id} = user, after_id, deadline) do
    {stop, done, counts} = n_walk(user, after_id, deadline)
    if counts != @zero, do: report(id, counts)

    case stop do
      stop when stop in [:done, :ok] -> :next
      {:cancel, _} -> :next
      stop -> {stop, %{"user" => id, "after" => done}}
    end
  end

  # The user's notes in fixed id windows (`IdWindows.reduce/5`), the
  # selection (`n_behind/0`) applied only inside each window: bounded rows
  # READ per statement. The accumulator carries the last id of the last
  # FINISHED window (`done`): a stop resumes after it, so a held window is
  # read again from its start. `{stop, done, counts}`, `stop` one of `:done`,
  # `:budget`, `:paused` (the switch), `:held` (a spent bucket) or an Oban
  # answer (`answer/2`).
  defp n_walk(user, after_id, deadline) do
    step = fn ids, _ctx, %{counts: counts} = acc ->
      cond do
        System.monotonic_time(:millisecond) > deadline ->
          {:halt, %{acc | stop: :budget}}

        not backfill_enabled?() ->
          {:halt, %{acc | stop: :paused}}

        true ->
          case n_window(user, ids, counts) do
            {:ok, counts} ->
              {:cont, %{acc | counts: counts, done: List.last(ids)}}

            {:held, counts} ->
              {:halt, %{acc | counts: counts, stop: :held}}

            {:error, reason, counts} ->
              {:halt, %{acc | counts: counts, stop: answer(user.id, reason)}}
          end
      end
    end

    acc = %{counts: @zero, done: after_id, stop: :done}

    case IdWindows.reduce({:user, user.id}, Note, acc, step,
           after: after_id,
           batch_size: @batch_size,
           fun_in_tenant: false
         ) do
      {:ok, %{stop: stop, done: done, counts: counts}} -> {stop, done, counts}
      {:error, reason} -> {answer(user.id, reason), after_id, @zero}
    end
  end

  # One window: its notes behind the version, their points' payloads, `n`
  # merged onto those without it (paced per page), then the notes stamped
  # (not one holding legacy v3 points: those never get `n`).
  defp n_window(user, ids, counts) do
    {notes, points} = n_batch(user.id, ids)

    with [_ | _] <- notes,
         {:ok, stored} <- read_payloads(user.id, points |> Map.values() |> List.flatten()),
         :ok <- RotationGate.check(user.id) do
      case write_n(n_pairs(notes, points, stored), counts) do
        {:ok, counts} ->
          for note <- notes,
              not legacy_points?(note, points, stored),
              do: stamp_version(note, hash: note.payload_hash)

          {:ok, Enum.reduce(notes, counts, fn _, acc -> bump(acc, :checked) end)}

        {:denied, counts} ->
          {:held, counts}

        {:error, _reason, _counts} = error ->
          error
      end
    else
      [] -> {:ok, counts}
      {:error, reason} -> {:error, reason, counts}
    end
  end

  defp n_batch(user_id, ids) do
    {:ok, result} =
      Repo.with_tenant(user_id, fn ->
        notes =
          n_behind()
          |> select([note: n], %{id: n.id, user_id: n.user_id, payload_hash: n.payload_hash})
          |> IdWindows.by_id(ids)
          |> Repo.all()

        {notes, n_points(notes)}
      end)

    result
  end

  # A window with no note behind reads no chunk.
  defp n_points([]), do: %{}

  defp n_points(notes) do
    note_ids = Enum.map(notes, & &1.id)

    from(c in Chunk,
      where: c.note_id in ^note_ids and not is_nil(c.qdrant_point_id),
      select: {c.note_id, c.qdrant_point_id}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp n_pairs(notes, points, stored) do
    for note <- notes,
        id <- Map.get(points, note.id, []),
        point = stored[id],
        point != nil and v5?(point) and not Map.has_key?(point, @n_key),
        do: {id, %{@n_key => FilterId.uuid(to_string(note.id))}}
  end

  # Page by page, each page capped at what the bucket has left this window
  # (a free peek), then spent with exactly that many points right before its
  # write. So a window's whole budget goes through (256 + 244 at 500/min),
  # and a job with nothing to write spends nothing. `{:denied, counts}` once
  # the window is spent (or a racing job took it first).
  defp write_n([], counts), do: {:ok, counts}

  defp write_n(pairs, counts) do
    cap = min(n_page(), RateLimiter.peek(@n_bucket, @n_window_ms, n_per_min()))
    {page, rest} = Enum.split(pairs, cap)
    size = length(page)

    with true <- size > 0,
         {:allow, _} <- RateLimiter.hit(@n_bucket, @n_window_ms, n_per_min(), :other, size),
         :ok <- Qdrant.set_payloads(Qdrant.collection_name(), page, caller: :reconcile) do
      write_n(rest, Map.update!(counts, :n_points, &(&1 + size)))
    else
      false -> {:denied, counts}
      {:deny, _ms} -> {:denied, counts}
      {:error, reason} -> {:error, reason, counts}
    end
  end

  @doc "The payload version from which every v5 point carries `n`."
  @spec n_version() :: 6
  def n_version, do: @n_version

  @doc "False while the `:payload_backfill` kill switch is off."
  @spec backfill_enabled?() :: boolean()
  def backfill_enabled?, do: ServiceConfig.get(:payload_backfill, true) != false

  defp n_per_min, do: ServiceConfig.get(:payload_backfill_points_per_min, @n_per_min)

  # A page never exceeds the bucket, or it could never be let through.
  defp n_page, do: min(@refresh_page, n_per_min())

  # A spent bucket re-queues to the window's edge plus up to 10 s of jitter,
  # so the job writes again in the very next window (a growing backoff would
  # leave windows idle).
  # ponytail: a fixed window lets up to 2x the rate through across a window
  # boundary (a full bucket at the end of one, another at the start of the
  # next). Accepted: the disk and optimizer gate (`Rebuild.qdrant_pace/1`) is
  # the real guard; a sliding window is the upgrade if 2x bursts ever show.
  @edge_jitter_s 10

  @doc false
  # Seconds to the end of the bucket's current window (Hammer's fix_window:
  # `div(now, scale)`), plus jitter. Pure in `now_ms` for the rate test.
  @spec edge_snooze(integer()) :: pos_integer()
  def edge_snooze(now_ms \\ System.system_time(:millisecond)) do
    to_edge_ms = @n_window_ms - rem(now_ms, @n_window_ms)
    div(to_edge_ms + 999, 1000) + :rand.uniform(@edge_jitter_s) - 1
  end

  @doc """
  The done check's second half: points a previous-release node upserted
  without `n` after their note was stamped (a rolling deploy). ONE scroll
  page of at most 256 v5 points without `n` per call, fleet-wide, resuming
  from the page the last call reached (`Engram.Maintenance.Cursor`, so it
  survives deploys); the notes they belong to (through their chunk rows)
  lose their version stamp, so the sweep selects them again. Points with no
  chunk row are orphans: `OrphanSweep` reaps them, no `n` filter matches
  them, and they count as clean. `:clean` only when a whole walk, start to
  end, requeued nobody AND began while every node wrote `n`
  (`cluster_writes_n?/1`): a point an older node wrote behind the walk's
  cursor is never seen, and the ledger's done is cached for good. Else how
  many users this page requeued. Options as `cluster_writes_n?/1`.
  """
  # ponytail: at most 16 pages (4,096 points without `n`) per pass, stopping
  # at the first page that requeues anyone. Hourly, that walks ~100k orphan
  # points a day; a bigger orphan backlog is `OrphanSweep`'s to reap first.
  @requeue_pages 16

  @spec requeue_unbackfilled(keyword()) :: :clean | {:ok, non_neg_integer()} | {:error, term()}
  def requeue_unbackfilled(opts \\ []) do
    walk =
      case Cursor.get(@requeue_cursor) do
        %{"offset" => _} = walk -> walk
        _ -> %{"fresh" => cluster_writes_n?(opts)}
      end

    requeue_pages(walk, Keyword.get(opts, :pages, @requeue_pages))
  end

  defp requeue_pages(walk, pages_left) do
    with {:ok, %{points: points, next_page_offset: next}} <-
           Qdrant.scroll(Qdrant.collection_name(),
             filter: missing_n_filter(),
             with_payload: ["u"],
             limit: @refresh_page,
             offset: walk["offset"]
           ) do
      users =
        points
        |> Enum.group_by(&FilterId.dashed(&1["payload"]["u"]), & &1["id"])
        |> Enum.filter(fn {uid, ids} -> unstamp_versions(uid, ids) > 0 end)
        |> Enum.map(&elem(&1, 0))

      walk = %{
        "offset" => next,
        "dirty" => walk["dirty"] == true or users != [],
        "fresh" => walk["fresh"] == true
      }

      if users != [] or pages_left <= 1 or next == nil,
        do: end_requeue(walk, users, next),
        else: requeue_pages(walk, pages_left - 1)
    end
  end

  # The end of the walk resets it (the next call starts a fresh one);
  # otherwise the next call resumes at `next`.
  defp end_requeue(walk, users, next) do
    if next == nil, do: Cursor.reset(@requeue_cursor), else: Cursor.put(@requeue_cursor, walk)

    cond do
      users != [] -> {:ok, enqueue_n(users)}
      next == nil and not walk["dirty"] and walk["fresh"] -> :clean
      true -> {:ok, 0}
    end
  end

  # NULLs the version stamp of the live notes these points belong to.
  defp unstamp_versions(user_id, point_ids) do
    case %User{id: user_id}
         |> Engram.Notes.note_ids_by_qdrant_points(point_ids)
         |> Map.values() do
      [] ->
        0

      note_ids ->
        {:ok, {n, _}} =
          Repo.with_tenant(user_id, fn ->
            Repo.update_all(
              from(s in NoteIndexState, where: s.note_id in ^Enum.uniq(note_ids)),
              set: [payload_version: nil]
            )
          end)

        n
    end
  end

  # `{:ok, writes, stamp_payload}`: the drifted points of each layout with
  # the payload each must hold, and the payload whose hash the row gets (the
  # v5 one when the note has v5 points, as a v5 pass stamps).
  defp plan_note(_user, note, [], v3_ids, stored) do
    payload = Indexing.expected_note_payload(note)
    {:ok, v3_writes(v3_ids, stored, payload), payload}
  end

  defp plan_note(user, note, v5_ids, v3_ids, stored) do
    with {:ok, plain} <- Crypto.maybe_decrypt_note_fields(note, user),
         {:ok, v5} <- Indexing.expected_v5_payload(plain, user) do
      want = normalize(v5)
      drifted = Enum.filter(v5_ids, &drifted?(stored[&1], want))
      writes = if drifted == [], do: [], else: [{:overwrite, drifted, v5}]
      {:ok, writes ++ v3_writes(v3_ids, stored, Indexing.expected_note_payload(note)), v5}
    else
      # The note's own ciphertext fails AEAD under the current DEK: it is
      # undecryptable, not unlucky. Anything else (no DEK, a contended load,
      # a key-provider error) is transient: the job fails and Oban backs off,
      # the note stays NULL for the daily re-check.
      {:error, :decrypt_failed} -> :skip
      {:error, reason} -> {:error, reason}
    end
  end

  defp v3_writes(ids, stored, payload) do
    want = normalize(payload)

    case Enum.reject(ids, &holds?(stored[&1], want)) do
      [] -> []
      drifted -> [{:set, drifted, payload}]
    end
  end

  defp normalize(payload), do: payload |> Jason.encode!() |> Jason.decode!()

  defp v5_keys, do: Enum.map(PayloadKeys.logical_names(), &PayloadKeys.short/1)

  defp heal_note(note, payload, [], counts, versioned?) do
    stamp(note, payload, wrote?: false, resparse?: false, versioned?: versioned?)
    {:cont, {:ok, counts}}
  end

  defp heal_note(note, payload, writes, counts, versioned?) do
    counts = bump(counts, :drifted)

    case Enum.reduce_while(writes, :ok, fn w, :ok -> write(w) end) do
      :ok ->
        # Drifted filter keys mean a rotation, so the sparse vectors (keyed
        # on the same filter key) are stale too: the keyword sweep redoes them.
        stamp(note, payload, wrote?: true, resparse?: true, versioned?: versioned?)
        {:cont, {:ok, bump(counts, :rewritten)}}

      # Logged once, with its class, where the hop answers Oban (`answer/2`).
      {:error, reason} ->
        {:halt, {:error, reason, counts}}
    end
  end

  defp write({op, ids, payload}) do
    fun = if op == :set, do: &Qdrant.set_payload/4, else: &Qdrant.overwrite_payload/4

    case fun.(Qdrant.collection_name(), ids, payload, caller: :reconcile) do
      :ok -> {:cont, :ok}
      err -> {:halt, err}
    end
  end

  # Compare-and-set on every column the payload is built from, and on the
  # stamp still being what the batch read (NULL for a first stamp, the old hash
  # for a version refresh): an index that committed since the read wrote (and
  # stamped) its own payload, and stamping ours would vouch for HMACs the row
  # no longer holds. A miss stays as it was for the next pass. A hit also
  # stamps the payload version the points now hold.
  @payload_columns [
    :content_hash,
    :vault_id,
    :path_hmac,
    :folder_hmac,
    :tags_hmac,
    :type_hmac,
    :fm_timestamp,
    :fm_created
  ]

  defp stamp(note, payload, opts) do
    wrote? = Keyword.fetch!(opts, :wrote?)
    resparse? = Keyword.fetch!(opts, :resparse?)

    guard =
      Enum.reduce(@payload_columns, same_stamp(note), fn
        col, acc ->
          case Map.fetch!(note, col) do
            nil -> dynamic([n], ^acc and is_nil(field(n, ^col)))
            value -> dynamic([n], ^acc and field(n, ^col) == ^value)
          end
      end)

    set = [payload_hash: Indexing.note_payload_hash(payload)]
    set = if resparse?, do: [{:keyword_version, nil} | set], else: set

    {:ok, :ok} =
      Repo.with_tenant(note.user_id, fn ->
        case Repo.update_all(from(n in Note, where: n.kind == "note", where: ^guard), set: set) do
          # We wrote this note's points from the row we read and the stamp
          # missed: an index committed (and stamped) in between, and our
          # write may have replaced its fresher payload.
          {0, _} when wrote? ->
            Indexing.unstamp_payload_hash(note)

          {0, _} ->
            :ok

          {_, _} ->
            if resparse?, do: queue_refresh(note)
            if Keyword.fetch!(opts, :versioned?), do: put_version(note), else: :ok
        end
      end)

    :ok
  end

  # The stamp this transaction clears is healed now, not by the keyword sweep:
  # once `IndexVersions` is done that sweep runs only in the daily re-verify,
  # so the note searched on stale sparse vectors for up to a day (the prod v5
  # gate's one keyword-stale note, 2026-11-02). Raises inside the clearing
  # transaction, so the NULL and its job commit together or not at all. A
  # running job does not count as pending: it read the old stamp, so its
  # compare-and-set misses and this one heals the note.
  # ponytail: one insert per drifted note; rare outside a DEK rotation.
  defp queue_refresh(note) do
    _ =
      RefreshKeywordVectors
      |> Jobs.reject_pending([note.id], executing: false)
      |> Enum.map(&RefreshKeywordVectors.new_for_note(&1, note.user_id))
      |> Jobs.insert_chunked()

    :ok
  end

  defp same_stamp(%{payload_hash: nil, id: id}),
    do: dynamic([n], n.id == ^id and is_nil(n.payload_hash))

  defp same_stamp(%{payload_hash: hash, id: id}),
    do: dynamic([n], n.id == ^id and n.payload_hash == ^hash)

  defp stamp_version(note, opts),
    do: elem(Repo.with_tenant(note.user_id, fn -> PayloadV6.stamp(note.id, opts) end), 0)

  defp put_version(note), do: PayloadV6.stamp(note.id)

  # A v3 point always carries `user_id` (`Indexing.expected_note_payload/1`);
  # a v5 one carries `u` instead.
  defp v5?(point), do: Map.has_key?(point, "u") or not Map.has_key?(point, "user_id")

  # A null and an absent key are the same to a filter.
  defp holds?(point, want), do: Enum.all?(want, fn {k, v} -> Map.get(point, k) == v end)

  defp bump(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  # One line per hop, and a counter per outcome, so a deploy can tell a heal
  # that verifies from one that rewrites the collection.
  defp report(user_id, counts) do
    for {outcome, n} <- counts,
        do: :telemetry.execute(@event, %{count: n}, %{outcome: outcome})

    Logger.info(
      "note payload reconcile hop",
      Metadata.with_category(:info, :oban, [user_id: user_id] ++ Map.to_list(counts))
    )
  end
end
