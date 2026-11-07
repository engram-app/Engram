defmodule Engram.Workers.ReconcileNotePayloads do
  @moduledoc """
  Keeps every indexed note's `payload_hash` stamped and its points carrying
  `n`, one user per chain for the heal, one fleet job for the backfill. Run
  by the `NotePayloadStamps` data migration and the Drain.

  Since R3a a point's payload is its note's identity (`u`, `v`, `n`,
  `Engram.Indexing.identity_payload/1`): nothing an edit, a rename or a DEK
  rotation changes, and filters resolve in Postgres. So the heal rewrites no
  point; old points keep stale filter keys nothing reads.

  Two kinds of job, each its own unique slot (`Engram.Jobs`, keys
  `[:user_id, :mode]`; the fleet job carries no `user_id`, so its slot is
  its mode alone), at the same priority, so Oban runs them by scheduled time
  and neither stream starves the other:

    * the HEAL (`mode: "heal"`, the default of `new/2`): a note whose
      `payload_hash` is NULL gets the identity hash, one UPDATE per batch: no
      Qdrant read, no decrypt. Queued by the Drain and the ledger. It never
      stamps the payload version: a missing `n` is the backfill's;
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
      deleted), and a legacy v3 point the whole identity (`u`, `v`, `n`),
      in pages capped at what the window has left and charged with their
      real size. No DEK, no decrypt, no upsert, no embedder call. Then the
      notes are stamped with the version (compare-and-set on the hash). A
      held window stores the cursor and the job
      queues itself again at the window's edge: one wake a window for the
      fleet, never one per user. A lap that reaches the last user ends the
      job; the hourly ledger queues it again while anyone is behind. A
      re-run rewrites nothing: stamped notes are not selected again,
      written points are skipped. A per-user `mode: "n"` job (0.77.0)
      cancels itself on wake and queues the fleet job.

  The backfill is rate-limited (the bucket above) on the single-slot
  `crdt_backfill` lane. Qdrant refusals and unapplied waits
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
  alias Engram.Crypto.RotationGate
  alias Engram.Indexing
  alias Engram.Indexing.PayloadV6
  alias Engram.Jobs
  alias Engram.Logger.Metadata
  alias Engram.Maintenance.Cursor
  alias Engram.Notes.{Chunk, Note, NoteIndexState}
  alias Engram.Rebuild
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.Vector.FilterId
  alias Engram.Vector.PayloadKeys
  alias Engram.Vector.Qdrant
  alias EngramWeb.RateLimiter

  require Logger

  @batch_size 200
  # Ops per `set_payloads` request (one point per op).
  @refresh_page 256
  @event [:engram, :indexing, :payload_reconcile]
  @cancelled_event [:engram, :indexing, :payload_reconcile_cancelled]
  @zero %{
    checked: 0,
    n_points: 0,
    legacy_v3: 0,
    legacy_v3_points: 0
  }
  @budget_ms 30_000

  # The payload version from which every v5 point carries `n`.
  @n_version 6
  @n_key PayloadKeys.short(:note)
  # The `n` backfill's fleet-wide token bucket (`:payload_backfill_points_per_min`).
  @n_bucket "payload_backfill_points"
  @n_window_ms 60_000
  @n_per_min 500
  # An `n` job's Oban priority: the heal's (`priority: 3` above), so they run
  # by scheduled time and a heal stream cannot starve the fleet job.
  @n_priority 3
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

    # Kept explicit: the priority is part of the `n` job's contract.
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
  # The cancel comes first: with the switch off it reads nothing.
  def perform(%Oban.Job{args: %{"mode" => "n"}}) do
    if backfill_enabled?(), do: :ok = ensure_fleet()
    {:cancel, :superseded}
  end

  # The heal (a NULL `payload_hash`, found by the Drain or the ledger): the
  # identity hash, no `n` gate, no Qdrant call.
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
  # An insert that conflicts with the pending job just as it starts
  # executing finds no pending one; the running job counts as present here.
  def ensure_fleet,
    do:
      if(fleet_job?(["executing"]),
        do: :ok,
        else: insert_fleet([], ["executing" | Jobs.pending_states()])
      )

  # The self re-queue. Oban's unique insert answers a conflict WITHOUT
  # inserting when another insert holds its advisory lock, so a conflict is
  # checked: a fleet job must be pending. If none is, the chain is lost until
  # the next hourly ledger pass re-adds it; logged so that shows.
  # Pending states only: the executing fleet job is the caller itself.
  defp requeue_fleet(wait, gated) do
    insert_fleet([schedule_in: wait, meta: %{"gated" => gated}], Jobs.pending_states())
  end

  # On a conflict, a fleet job must be in one of `present` states.
  defp insert_fleet(opts, present) do
    {:ok, job} = insert_fun().(new(%{"mode" => @fleet_mode}, opts))

    if job.conflict? and not fleet_job?(present) do
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
    notes = batch(user_id, after_id)

    cond do
      notes == [] ->
        {:done, counts}

      System.monotonic_time(:millisecond) > deadline ->
        {{:more, after_id}, counts}

      true ->
        stamp_identity(user_id, notes)
        counts = Map.update!(counts, :checked, &(&1 + length(notes)))

        if length(notes) < @batch_size,
          do: {:done, counts},
          else: heal(user, List.last(notes).id, deadline, counts)
    end
  end

  # One UPDATE for the batch: each NULL row gets its own identity hash. Only
  # while NULL: an index pass stamps the same hash, so a race changes nothing.
  defp stamp_identity(user_id, notes) do
    ids = Enum.map(notes, &Ecto.UUID.dump!(&1.id))
    hashes = Enum.map(notes, &Indexing.identity_hash/1)

    {:ok, {_, _}} =
      Repo.with_tenant(user_id, fn ->
        from(n in Note,
          join:
            h in fragment(
              "SELECT * FROM unnest(?::uuid[], ?::bytea[]) AS h(id, hash)",
              ^ids,
              ^hashes
            ),
          on: n.id == h.id,
          where: n.kind == "note" and is_nil(n.payload_hash),
          update: [set: [payload_hash: h.hash]]
        )
        |> Repo.update_all([])
      end)

    :ok
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
      from(n in unstamped(),
        where: n.user_id == ^user_id,
        order_by: n.id,
        limit: @batch_size,
        select: %{id: n.id, user_id: n.user_id, vault_id: n.vault_id}
      )

    query = if after_id, do: where(query, [n], n.id > ^after_id), else: query
    {:ok, notes} = Repo.with_tenant(user_id, fn -> Repo.all(query) end)
    notes
  end

  # `%{point_id => payload}` for the points that exist, the layout keys only
  # (`v5?/1`, `n`).
  defp read_payloads(user_id, ids) do
    keys = ["u", "user_id", @n_key]

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

  # How many of the note's points are legacy v3 (0: none).
  defp v3_points(note, points, stored),
    do: Enum.count(Map.get(points, note.id, []), &(stored[&1] && not v5?(stored[&1])))

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

    {result, tally} = fleet_walk(Cursor.get(@fleet_cursor), deadline, fleet_zero())

    # One line per run with its totals (prod Loki, `loki_ship`). Skipped
    # users (`locked`) and notes left alone for their legacy v3 points
    # (`legacy_v3`, never given `n` nor stamped) keep the ledger open, so
    # this line says why a lap repeats and what holds R3.
    Logger.info(
      "note payload n fleet run",
      Metadata.with_category(:info, :oban, Map.to_list(tally))
    )

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
  # With the run's tally: the walked users' counts summed, and `locked`, how
  # many rotation-locked users it passed over.
  defp fleet_walk(cursor, deadline, tally) do
    case next_users(cursor) do
      [] ->
        {:lap, tally}

      users ->
        case Enum.reduce_while(users, {cursor, tally}, &fleet_user(&1, &2, deadline)) do
          {:stop, stop, at, tally} -> {{stop, at}, tally}
          {cursor, tally} -> fleet_walk(cursor, deadline, tally)
        end
    end
  end

  defp fleet_zero, do: Map.put(@zero, :locked, 0)

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
  defp fleet_user(%User{id: id} = user, {cursor, tally}, deadline) do
    after_id = if match?(%{"user" => ^id}, cursor), do: cursor["after"]
    past = %{"past" => id}

    cond do
      # A user with no notes reads no window, so the budget is checked here too.
      System.monotonic_time(:millisecond) > deadline ->
        {:halt, {:stop, :budget, %{"user" => id, "after" => after_id}, tally}}

      RotationGate.check_user(user) != :ok ->
        {:cont, {past, bump(tally, :locked)}}

      # A done user costs this one probe, not a walk of its notes.
      not n_behind?(id) ->
        {:cont, {past, tally}}

      true ->
        case walk_user(user, after_id, deadline) do
          {:next, counts} -> {:cont, {past, add(tally, counts)}}
          {stop, at, counts} -> {:halt, {:stop, stop, at, add(tally, counts)}}
        end
    end
  end

  # One EXISTS on `note_index_state` through its partial index
  # `note_index_state_n_behind` (empty in steady state), so a done user costs
  # a few index pages, not a read of its notes. The walk's own selection
  # (`n_behind/0`) still decides per window.
  defp n_behind?(user_id) do
    {:ok, any} = Repo.with_tenant(user_id, fn -> Repo.exists?(n_behind_probe(user_id)) end)
    any
  end

  @doc false
  # The probe query, for the plan test (`drain_test.exs`). Its predicate is
  # the partial index's text with literals (`coalesce(?, 5) < 6`, the
  # baseline and `@n_version`): Postgres uses a partial index only for a
  # query that implies its predicate.
  @spec n_behind_probe(Ecto.UUID.t()) :: Ecto.Query.t()
  def n_behind_probe(user_id) do
    from(s in NoteIndexState,
      where: s.user_id == ^user_id and s.points > 0 and not is_nil(s.payload_hash),
      where: fragment("coalesce(?, 5) < 6", s.payload_version),
      select: 1
    )
  end

  # `{:next, counts}` (the user is done, gone or refused with a 4xx), or
  # `{stop, cursor, counts}` to resume it from.
  defp walk_user(%User{id: id} = user, after_id, deadline) do
    {stop, done, counts} = n_walk(user, after_id, deadline)
    if counts != @zero, do: report(id, counts)

    case stop do
      stop when stop in [:done, :ok] -> {:next, counts}
      {:cancel, _} -> {:next, counts}
      stop -> {stop, %{"user" => id, "after" => done}, counts}
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
  # merged onto those without it (paced per page), then the notes stamped. A
  # legacy v3 point (no `u`) gets the whole identity payload (`u`, `v`, `n`)
  # merged instead: R3a never rewrites a reused point, so nothing else would
  # ever give it `n` (design (g)1). Notes holding v3 points are still counted
  # (`legacy_v3`, their v3 points in `legacy_v3_points`).
  defp n_window(user, ids, counts) do
    {notes, points} = n_batch(user.id, ids)

    with [_ | _] <- notes,
         {:ok, stored} <- read_payloads(user.id, points |> Map.values() |> List.flatten()),
         :ok <- RotationGate.check(user.id) do
      case write_n(n_pairs(notes, points, stored), counts) do
        {:ok, counts} ->
          {:ok, Enum.reduce(notes, counts, &stamp_or_count(&1, points, stored, &2))}

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

  defp stamp_or_count(note, points, stored, counts) do
    counts = bump(counts, :checked)
    stamp_version(note, hash: note.payload_hash)

    case v3_points(note, points, stored) do
      0 -> counts
      v3 -> counts |> bump(:legacy_v3) |> Map.update!(:legacy_v3_points, &(&1 + v3))
    end
  end

  defp n_batch(user_id, ids) do
    {:ok, result} =
      Repo.with_tenant(user_id, fn ->
        notes =
          n_behind()
          |> select([note: n], %{
            id: n.id,
            user_id: n.user_id,
            vault_id: n.vault_id,
            payload_hash: n.payload_hash
          })
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
        point != nil and not Map.has_key?(point, @n_key),
        do: {id, n_payload(note, point)}
  end

  defp n_payload(note, point) do
    if v5?(point),
      do: %{@n_key => FilterId.uuid(to_string(note.id))},
      else: Indexing.identity_payload(note)
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

    requeue_pages(walk, Keyword.get(opts, :pages, @requeue_pages), opts)
  end

  defp requeue_pages(walk, pages_left, opts) do
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
        # Re-checked on every call: an older node that joins mid-walk can
        # write points without `n` behind the cursor.
        "fresh" => walk["fresh"] == true and cluster_writes_n?(opts)
      }

      if users != [] or pages_left <= 1 or next == nil,
        do: end_requeue(walk, users, next),
        else: requeue_pages(walk, pages_left - 1, opts)
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

  defp stamp_version(note, opts),
    do: elem(Repo.with_tenant(note.user_id, fn -> PayloadV6.stamp(note.id, opts) end), 0)

  # A v3 point always carries `user_id`; a v5 one carries `u` instead.
  defp v5?(point), do: Map.has_key?(point, "u") or not Map.has_key?(point, "user_id")

  defp bump(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  defp add(tally, counts), do: Map.merge(tally, counts, fn _, a, b -> a + b end)

  @doc "Every `outcome` tag `[:engram, :indexing, :payload_reconcile]` carries."
  @spec outcomes() :: [atom()]
  def outcomes, do: Map.keys(@zero)

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
