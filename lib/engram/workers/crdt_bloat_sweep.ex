defmodule Engram.Workers.CrdtBloatSweep do
  @moduledoc """
  Whole-population measurement of CRDT doc bloat (#1706), every 6 hours.

  `Engram.Notes.CrdtCheckpoint` emits a per-checkpoint bloat sample, but that
  stream is biased in two ways that make it the wrong thing to size the database
  against. It only sees notes that were OPENED, and it re-samples a frequently
  synced note on every open — so the distribution it describes is "notes people
  touch", weighted by how often they touch them. In prod 99% of rooms are
  handshake-minted rather than edit-minted, and at ~390 rooms/day a p99 over the
  live histogram needs weeks to mean anything.

  This sweep answers the question the checkpoint stream cannot: across EVERY
  stored note, how far does `crdt_state` run ahead of the content it encodes.

  Every 6 hours rather than daily because it publishes `last_value` gauges,
  which live only on the node that ran the job: a task replacement clears them,
  and on a daily cadence that is up to 24h of "No data". See the staleness
  contract in `Engram.PromEx.Crdt`.

  ## It never decrypts anything

  AES-GCM ciphertext is the same length as its plaintext plus a fixed 16-byte
  tag (`Engram.Crypto.Envelope.tag_bytes/0`); the nonce lives in its own column.
  So `octet_length(col) - tag_bytes()` is the exact plaintext size, and the
  whole measurement is column lengths — no DEK lookup, no key material, no
  plaintext in memory, and one aggregate query rather than a walk. The fixed
  overhead cancels in the ratio anyway; it is subtracted so the reported BYTE
  totals are true sizes rather than sizes plus a per-row constant.

  ### "Just column lengths" is not free, and the cost scales with the problem

  `octet_length` on a `bytea` returns the UNCOMPRESSED length, so Postgres must
  materialize and de-TOAST every value to answer it. `crdt_state_ciphertext` is
  the largest column in the database, which means this reads and decompresses
  the entire CRDT corpus on the primary on every run, inside a 5-minute
  statement timeout.

  That is affordable at current scale and deliberately accepted — but note the
  shape: the cost grows with exactly the quantity being measured, so it
  degrades fastest in the scenario #609 exists to address. If this starts
  timing out, the fix is not a longer timeout.

  `pg_column_size/1` answers a storage question from the on-disk size without
  de-TOASTing, and would be the cheap swap — but it measures COMPRESSED bytes,
  which is a different metric than the plaintext ratio this worker reports.
  Changing it changes what the numbers mean, so it is not a drop-in. Tracked
  separately rather than done quietly here.

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

  alias Engram.Crypto.Envelope
  alias Engram.Logger.Metadata
  alias Engram.Notes.CrdtBloat
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
    if tenancy_unsafe?() do
      refuse()
    else
      do_measure_and_emit()
    end
  end

  defp refuse do
    Logger.error(
      "crdt_bloat_sweep refusing to run: RLS enforcement could not be ruled out and no " <>
        "maintenance pool is configured, so the notes read would return zero rows and the " <>
        "sweep would report an empty database as a healthy one",
      Metadata.with_category(:error, :oban, [])
    )

    {:error, :tenancy_unsafe}
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
          count(*) FILTER (WHERE has_state AND big AND ratio > $2::float8)::bigint
        FROM (
          SELECT
            n.crdt_state_ciphertext IS NOT NULL AS has_state,
            greatest(octet_length(n.crdt_state_ciphertext) - $1::int, 0) AS state_bytes,
            greatest(octet_length(n.content_ciphertext) - $1::int, 0) AS content_bytes,
            greatest(octet_length(n.content_ciphertext) - $1::int, 0) >= $3::int AS big,
            greatest(octet_length(n.crdt_state_ciphertext) - $1::int, 0)::float8
              / greatest(octet_length(n.content_ciphertext) - $1::int, 1)::float8 AS ratio
          FROM notes n
          WHERE n.deleted_at IS NULL
            AND n.kind = 'note'
        ) sized
        """,
        [tag, @bloat_threshold * 1.0, CrdtBloat.min_content_bytes()],
        timeout: :timer.minutes(5)
      )

    [notes, with_state, measured, p50, p90, p99, max, state_bytes, content_bytes, over] = row

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
  end

  # `enforced?/0` answers a live query and reports `true` when it cannot tell, so
  # a transient DB blip refuses this slot rather than sweeping blind. That is the
  # safe direction — a lost reading self-heals in 6h, a fabricated zero does not
  # — but it means the refusal message must not assert RLS *is* enforced.
  defp tenancy_unsafe? do
    Repo.maintenance() == Repo and Engram.Repo.TenancyGuard.enforced?()
  end

  defp fmt(f) when is_float(f), do: Float.round(f, 2)
end
