defmodule Engram.Workers.CrdtBloatSweep do
  @moduledoc """
  Whole-population measurement of CRDT doc bloat (#1706), hourly.

  `Engram.Notes.CrdtCheckpoint` emits a per-checkpoint bloat sample, but that
  stream is biased in two ways that make it the wrong thing to size the database
  against. It only sees notes that were OPENED, and it re-samples a frequently
  synced note on every open — so the distribution it describes is "notes people
  touch", weighted by how often they touch them. In prod 99% of rooms are
  handshake-minted rather than edit-minted, and at ~390 rooms/day a p99 over the
  live histogram needs weeks to mean anything.

  This sweep answers the question the checkpoint stream cannot: across EVERY
  stored note, how far does `crdt_state` run ahead of the content it encodes.

  Hourly because it publishes `last_value` gauges, which live only on the node
  that ran the job: a task replacement clears them, leaving "No data" until the
  next run. See the staleness contract in `Engram.PromEx.Crdt`.

  ## It never decrypts anything

  A stored ciphertext is its payload plus a fixed 16-byte tag
  (`Engram.Crypto.Envelope.tag_bytes/0`); the nonce lives in its own column.
  So `octet_length(col) - tag_bytes()` is the exact STORED payload size, and the
  whole measurement is column lengths — no DEK lookup, no key material, no
  plaintext in memory, and one aggregate query rather than a walk. The fixed
  overhead cancels in the ratio anyway; it is subtracted so the reported BYTE
  totals are true stored sizes rather than sizes plus a per-row constant.

  ## The gauges report STORED bytes (#1872 R2)

  Content and `crdt_state` are compressed before encryption (format 1), so the
  payload is no longer the text size: a compressed row reports its zstd size, a
  format 1 raw row its plaintext plus the 1-byte format prefix, a format 0 row
  its plaintext size. That is what the page cache and disk actually hold, which
  is what these gauges are for. Metric names are unchanged (dashboards). The
  `state/content` ratio is only a like-for-like bloat measure once both columns
  of a note share a format, i.e. after the backfill; until then it mixes
  compressed and plain rows.

  ### `octet_length` does NOT de-TOAST, despite looking like it must

  Worth stating because the opposite is the intuitive reading, and it was
  asserted confidently in review of this worker before anyone measured it.

  `byteaoctetlen` calls `toast_raw_datum_size()`, which reads `va_rawsize`
  straight out of the TOAST pointer — no chunk fetch. So this aggregate touches
  the heap only, and its cost scales with ROW COUNT, not with the size of the
  state being measured. Measured on PG 18, 300 rows x 32 KB bytea, all
  out-of-line:

      sum(octet_length(b))    shared hit=2
      sum(pg_column_size(b))  shared hit=2
      sum(get_byte(b, 0))     shared hit=1502   <- an actual de-TOAST

  `pg_column_size/1` is therefore NOT a cheaper alternative; it reads the same
  varlena header and measured identically. The only reason to prefer one is
  which number you want — raw plaintext bytes versus on-disk compressed bytes
  — and for AES-GCM ciphertext (incompressible, stored EXTERNAL) those differ
  by about four bytes anyway.

  ## Scope

  The population is every live `kind='note'` row, not only those carrying CRDT
  state — `state_bytes_total / content_bytes_total` is sold as the
  reclaimable-storage estimate #609 sizes against, and scoping it to rows WITH
  state would drop the cohort migration 20260706210000 left with a NULL
  `crdt_state` that nothing re-seeds (see `CrdtCheckpoint`), reporting a ratio
  higher than the database's. `notes_with_state` reports that split.

  `kind='note'` is explicit rather than implied. Folder rows live in the same
  table and are allowed a NULL `content_ciphertext`; nothing stops one acquiring
  CRDT state, and it would enter the population as `content_bytes = 0`.

  ## Percentiles exclude trivially small notes

  Ratio percentiles are computed only over notes above
  `Engram.Notes.CrdtBloat.min_content_bytes/0`; `notes_measured` reports that
  denominator alongside `notes`. Byte totals stay over the full population —
  those are real storage no matter how small the note. The staging measurement
  that forced this split is recorded in `CrdtBloat`.

  ## Freshness

  `measured_at_unix` rides along with every reading so a consumer can tell a
  frozen gauge from a current one. Without it a sweep that has been failing for
  a week is indistinguishable, on every panel, from one that ran a minute ago.

  ## Why it refuses rather than reporting zero

  `notes` carries RLS. Where enforcement is on and no maintenance pool is
  configured, this query returns zero rows — and a sweep that reports "0 notes,
  ratio 0" is indistinguishable from a healthy empty database. That is a lying
  oracle, and the gauges it writes would be believed. Same guard, and same
  reasoning, as `Engram.Workers.OrphanSweep`.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias Engram.Crypto.{Envelope, HMAC}
  alias Engram.DataMigrations.NoteSizes
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtBloat, Note, NoteBody}
  alias Engram.Repo

  require Logger

  @typedoc """
  One sweep reading.

  Spelled out rather than `map()` because dialyzer then catches a key renamed
  here and not at the call site. It does NOT catch a measurement added without a
  matching PromEx gauge — nothing does; `Engram.PromEx.CrdtTest` asserts a
  hardcoded key list, so both have to be edited by hand.
  """
  @type measurements :: %{
          optional(:notes_save_rate_over_threshold) => non_neg_integer(),
          optional(:save_rate_max_per_hour) => non_neg_integer(),
          notes: non_neg_integer(),
          notes_with_state: non_neg_integer(),
          notes_measured: non_neg_integer(),
          bloat_ratio_p50: float(),
          bloat_ratio_p90: float(),
          bloat_ratio_p99: float(),
          bloat_ratio_max: float(),
          state_bytes_total: non_neg_integer(),
          content_bytes_total: non_neg_integer(),
          notes_over_threshold: non_neg_integer(),
          measured_at_unix: integer()
        }

  @event [:engram, :crdt, :state_sweep]

  # With no baseline, the first window is the last hour plus slack.
  @first_window_s 3_900

  # Matches the `>5x` panel on the engram-crdt dashboard. Changing it here
  # without changing the `le` bucket there makes the two disagree silently.
  @bloat_threshold 5

  # Both halves are needed. `timeout/1` bounds the JOB; Ecto bounds the QUERY
  # separately and defaults to 15s, so a job budget alone would still have this
  # die mid-scan on a large table with nothing but a DBConnection error and a
  # discard to show for it.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case measure_and_emit() do
      {:error, :tenancy_unsafe} = err -> err
      _measurements -> :ok
    end
  end

  @doc """
  Run the aggregate and emit `[:engram, :crdt, :state_sweep]`.

  Public so the sweep can be triggered by hand against a real database without
  waiting for a cron slot. Returns the measurements map, or
  `{:error, :tenancy_unsafe}`.

  The refuse-guard lives HERE rather than in `perform/1` on purpose. It was in
  the caller, which left the advertised hand-invocation route bypassing it: one
  `iex` call on a SaaS node with RLS enforced and no maintenance pool would
  write `notes=0, ratio=0` into gauges that never expire, and they would be
  re-served on every scrape until the next sweep — the exact lying oracle the
  guard exists to prevent, reachable through the documented entry point.
  """
  @spec measure_and_emit() :: measurements() | {:error, :tenancy_unsafe}
  def measure_and_emit do
    Repo.maintenance_only(
      "crdt_bloat_sweep",
      "RLS enforcement could not be ruled out and no maintenance pool is configured, so " <>
        "the notes read would return zero rows and the sweep would report an empty " <>
        "database as a healthy one",
      &do_measure_and_emit/0
    )
  end

  defp do_measure_and_emit do
    measurements = measure()

    :telemetry.execute(@event, measurements, %{})

    Logger.info(
      "crdt_bloat_sweep notes=#{measurements.notes} with_state=#{measurements.notes_with_state} measured=#{measurements.notes_measured} p50=#{fmt(measurements.bloat_ratio_p50)} " <>
        "p90=#{fmt(measurements.bloat_ratio_p90)} p99=#{fmt(measurements.bloat_ratio_p99)} " <>
        "max=#{fmt(measurements.bloat_ratio_max)} over_threshold=#{measurements.notes_over_threshold} " <>
        "state_bytes=#{measurements.state_bytes_total}",
      Metadata.with_category(:info, :oban, [])
    )

    measurements
  end

  @spec measure() :: measurements()
  defp measure do
    tag = Envelope.tag_bytes()
    now = DateTime.utc_now()
    baseline = baseline(now)
    since = if baseline, do: elem(baseline, 0), else: DateTime.add(now, -@first_window_s)
    narrow? = NoteSizes.done?()

    {written, owners, commit} =
      if narrow?, do: written_versions(), else: {nil, nil, fn -> :ok end}

    _ = if narrow?, do: refresh_sizes(Map.keys(written) ++ backstop_ids())

    %Postgrex.Result{rows: [row]} =
      Repo.maintenance().query!(
        """
        SELECT
          count(*)::bigint,
          count(*) FILTER (WHERE has_state)::bigint,
          count(*) FILTER (WHERE has_state AND big)::bigint,
          coalesce(
            percentile_cont(0.5) WITHIN GROUP (ORDER BY ratio) FILTER (WHERE has_state AND big), 0
          )::float8,
          coalesce(
            percentile_cont(0.9) WITHIN GROUP (ORDER BY ratio) FILTER (WHERE has_state AND big), 0
          )::float8,
          coalesce(
            percentile_cont(0.99) WITHIN GROUP (ORDER BY ratio) FILTER (WHERE has_state AND big), 0
          )::float8,
          coalesce(max(ratio) FILTER (WHERE has_state AND big), 0)::float8,
          coalesce(sum(state_bytes), 0)::bigint,
          coalesce(sum(content_bytes), 0)::bigint,
          count(*) FILTER (
            WHERE has_state AND big AND ratio > $2::float8 AND state_bytes >= $4::int
          )::bigint,
          -- All ORDER BY id: aggregates have no shared order otherwise, and
          -- the arrays are zipped id to version and id to owner.
          coalesce(array_agg(id ORDER BY id) FILTER (WHERE written), '{}'),
          coalesce(array_agg(version ORDER BY id) FILTER (WHERE written), '{}'),
          coalesce(array_agg(user_id ORDER BY id) FILTER (WHERE written), '{}')
        FROM (
          #{sized_rows(narrow?)}
        ) sized
        """,
        [
          tag,
          @bloat_threshold * 1.0,
          CrdtBloat.min_content_bytes(),
          CrdtBloat.alert_min_state_bytes(),
          # A UTC DateTime: `n.updated_at >= $5` types it from the column, so
          # it is the same instant in `timestamp` or `timestamptz`.
          since
        ],
        timeout: :timer.minutes(5)
      )

    [
      notes,
      with_state,
      measured,
      p50,
      p90,
      p99,
      max,
      state_bytes,
      content_bytes,
      over,
      ids,
      versions,
      users
    ] =
      row

    ids = Enum.map(ids, &Ecto.UUID.load!/1)
    versions = if narrow?, do: written, else: Map.new(Enum.zip(ids, versions))

    owners =
      if narrow?, do: owners, else: Map.new(Enum.zip(ids, Enum.map(users, &Ecto.UUID.load!/1)))

    Engram.Cache.put(:crdt_sweep_versions, :last, {now, versions})
    # The feed moves only once its rows are refreshed and measured.
    :ok = commit.()

    %{
      notes: notes,
      notes_with_state: with_state,
      notes_measured: measured,
      bloat_ratio_p50: p50,
      bloat_ratio_p90: p90,
      bloat_ratio_p99: p99,
      bloat_ratio_max: max,
      state_bytes_total: state_bytes,
      content_bytes_total: content_bytes,
      notes_over_threshold: over,
      # A `last_value` gauge never expires, so a sweep that stops running keeps
      # serving its final reading and looks exactly like a healthy one. The
      # panels could say "absent means it has not run"; nothing could say
      # "frozen". `time() - this` is that missing signal, and it costs a field.
      measured_at_unix: System.system_time(:second)
    }
    |> Map.merge(save_rate(baseline, now, versions, owners))
  end

  # The per-note sizes, one row per live note. Once `NoteSizes` has filled the
  # narrow `note_index_state` columns (`refresh_sizes/1` keeps them current)
  # the sweep reads that table; until then (a fresh upgrade) it
  # aggregates every live note and its body row, the slow scan the narrow
  # read replaces.
  # Same column names and values either way.
  defp sized_rows(narrow?) do
    if narrow? do
      # The narrow copy on `note_index_state` (`refresh_sizes/1` brought the
      # notes written since the last sweep up to date first). Written ids and
      # versions come from `written_versions/1`, so `written` is false here.
      """
      SELECT
        s.note_id AS id,
        0 AS version,
        NULL::uuid AS user_id,
        false AS written,
        s.has_state,
        coalesce(s.state_bytes, 0) AS state_bytes,
        coalesce(s.content_bytes, 0) AS content_bytes,
        coalesce(s.content_bytes, 0) >= $3::int AS big,
        coalesce(s.state_bytes, 0)::float8 / greatest(coalesce(s.content_bytes, 0), 1)::float8 AS ratio
      FROM note_index_state s
      -- $1 and $5 are bound for both shapes; Postgres rejects an unused parameter.
      WHERE s.note_live AND $1::int >= 0 AND $5::timestamptz IS NOT NULL
      """
    else
      # Ciphertext lengths of each live note's body, read through `NoteBody`
      # (the `note_bodies` copy, else the `notes` one for a note with no body
      # row), so this path and every other body read agree. The subquery
      # names its columns; it has no parameters of its own.
      {lengths, []} = Repo.to_sql(:all, from(w in subquery(wide_lengths()), select: w))

      """
      SELECT
        w.id,
        w.version,
        w.user_id,
        w.updated_at >= $5 AS written,
        w.state_len > 0 AS has_state,
        greatest(w.state_len - $1::int, 0) AS state_bytes,
        greatest(w.content_len - $1::int, 0) AS content_bytes,
        greatest(w.content_len - $1::int, 0) >= $3::int AS big,
        greatest(w.state_len - $1::int, 0)::float8
          / greatest(w.content_len - $1::int, 1)::float8 AS ratio
      FROM (#{lengths}) w
      """
    end
  end

  # `NoteBody.byte_length/1` is 0 for a NULL ciphertext; a stored one is
  # never 0 bytes (the 16-byte tag), so `state_len > 0` is "has state".
  defp wide_lengths do
    from(n in Note,
      where: is_nil(n.deleted_at) and n.kind == "note",
      select: %{id: n.id, version: n.version, user_id: n.user_id, updated_at: n.updated_at}
    )
    |> NoteBody.join()
    |> select_merge(
      ^%{content_len: NoteBody.byte_length(:content), state_len: NoteBody.byte_length(:crdt)}
    )
  end

  # Copies the body sizes (`note_bodies`, BEFORE-trigger columns) of the notes
  # written since the last sweep, and of the backstop window, to the narrow
  # `note_index_state` copy: PK lookups, at most one HOT row version per
  # changed note per sweep, off the save path; an unchanged row is not written.
  @refresh_batch 5_000
  defp refresh_sizes(ids) do
    ids
    |> Enum.uniq()
    |> Enum.chunk_every(@refresh_batch)
    |> Enum.each(fn ids ->
      Repo.maintenance().query!(
        """
        UPDATE note_index_state s SET
          content_bytes = b.content_bytes,
          state_bytes = b.state_bytes,
          has_state = b.state_bytes IS NOT NULL
        FROM note_bodies b
        WHERE b.note_id = s.note_id AND s.note_id = ANY($1::uuid[])
          AND (s.content_bytes, s.state_bytes, s.has_state)
              IS DISTINCT FROM (b.content_bytes, b.state_bytes, b.state_bytes IS NOT NULL)
        """,
        [Enum.map(ids, &Ecto.UUID.dump!/1)],
        timeout: :timer.minutes(5)
      )
    end)
  end

  # Versions and owners of the live notes written since the last sweep, from
  # the sync change sequence (`Engram.Maintenance.ChangeFeed`, index reads only).
  defp written_versions do
    {rows, commit} = Engram.Maintenance.ChangeFeed.changed("crdt_bloat_sweep")
    {Map.new(rows, &{&1.id, &1.version}), Map.new(rows, &{&1.id, &1.user_id}), commit}
  end

  # Backstop for size changes the change feed cannot see (a snapshot
  # compaction takes no seq): the next `@backstop_rows` state rows in key
  # order from a persisted cursor, wrapping at the end, so every copy is
  # re-checked within rows / @backstop_rows hours.
  @backstop_rows 20_000
  defp backstop_ids do
    from = Engram.Maintenance.Cursor.get("crdt_bloat_sweep:sizes")

    %Postgrex.Result{rows: rows} =
      Repo.maintenance().query!(
        """
        SELECT note_id FROM note_index_state
        WHERE ($1::uuid IS NULL OR note_id > $1) ORDER BY note_id LIMIT $2
        """,
        [from && Ecto.UUID.dump!(from["note_id"]), @backstop_rows],
        timeout: :timer.minutes(2)
      )

    ids = Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
    last = List.last(ids)

    :ok =
      Engram.Maintenance.Cursor.advance(
        "crdt_bloat_sweep:sizes",
        last && %{"note_id" => last},
        length(ids),
        @backstop_rows
      )

    ids
  end

  # The previous sweep's baseline, when this node has one young enough to diff.
  defp baseline(now) do
    case Engram.Cache.get(:crdt_sweep_versions, :last) do
      {:ok, {%DateTime{} = at, %{} = versions}} ->
        if DateTime.diff(now, at) <= 3 * 3_600, do: {at, versions}

      _ ->
        nil
    end
  end

  # Per-note writes per hour (#2097's "edits" are these: every checkpoint and
  # every REST/MCP write bumps `notes.version`), as the version delta of each
  # note written since the last sweep against that sweep's baseline. A
  # machine edit loop shows here long before it shows in bytes.
  #
  # Without a baseline (first run on this node, or the cache expired) both
  # keys are left OUT rather than reported as 0, so the gauges keep their last
  # value instead of claiming "no loop" about an hour nobody measured.
  #
  # ponytail: a note first written in this window has no baseline version, so
  # a loop that starts mid-hour shows one sweep later. The baseline only holds
  # notes written in the previous window, which keeps it small.
  # Most save-loop notes one sweep logs (`crdt_save_loop_note`), fastest first.
  @save_loop_log_cap 20

  @doc false
  def save_loop_log_cap, do: @save_loop_log_cap

  defp save_rate(nil, _now, _versions, _owners), do: %{}

  defp save_rate({at, before}, now, versions, owners) do
    # Per hour, never faster: the cron is hourly, and a hand-run sweep minutes
    # after the last must not divide a few writes by a few minutes.
    hours = max(DateTime.diff(now, at), 3_600) / 3_600

    rates =
      for {id, v} <- versions,
          prev = before[id],
          is_integer(prev),
          do: {id, round((v - prev) / hours)}

    looping = for {_id, rate} = r <- rates, rate > CrdtBloat.save_rate_threshold(), do: r
    log_save_loops(looping, owners)

    %{
      notes_save_rate_over_threshold: length(looping),
      save_rate_max_per_hour: rates |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)
    }
  end

  # One line per looping note, fastest first, so `engram-prod-crdt-save-loop`
  # can be pinned to a note. Ids are HMAC'd (never raw, never a path or title).
  defp log_save_loops(looping, owners) do
    looping
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(@save_loop_log_cap)
    |> Enum.each(fn {id, rate} ->
      Logger.warning(
        "crdt_save_loop_note note=#{HMAC.hash_id(id)} user=#{HMAC.hash_user_id(owners[id])} " <>
          "rate_per_hour=#{rate} threshold=#{CrdtBloat.save_rate_threshold()}",
        Metadata.with_category(:warning, :oban, [])
      )
    end)
  end

  # `enforced?/0` answers a live query and reports `true` when it cannot tell, so
  # a transient DB blip refuses this slot rather than sweeping blind. That is the
  # safe direction — a lost reading self-heals in 1h, a fabricated zero does not
  # — but it means the refusal message must not assert RLS *is* enforced.

  defp fmt(f) when is_float(f), do: Float.round(f, 2)
end
