defmodule Engram.Workers.CrdtBloatSweep do
  @moduledoc """
  Daily whole-population measurement of CRDT doc bloat (#1706).

  `Engram.Notes.CrdtCheckpoint` emits a per-checkpoint bloat sample, but that
  stream is biased in two ways that make it the wrong thing to size the database
  against. It only sees notes that were OPENED, and it re-samples a frequently
  synced note on every open — so the distribution it describes is "notes people
  touch", weighted by how often they touch them. In prod 99% of rooms are
  handshake-minted rather than edit-minted, and at ~390 rooms/day a p99 over the
  live histogram needs weeks to mean anything.

  This sweep answers the question the checkpoint stream cannot: across EVERY
  stored note, how far does `crdt_state` run ahead of the content it encodes.

  ## It never decrypts anything

  AES-GCM ciphertext is the same length as its plaintext plus a fixed 16-byte
  tag (`Engram.Crypto.Envelope.tag_bytes/0`); the nonce lives in its own column.
  So `octet_length(col) - tag_bytes()` is the exact plaintext size, and the
  whole measurement is column lengths — no DEK lookup, no key material, no
  plaintext in memory, and one aggregate query rather than a walk. The fixed
  overhead cancels in the ratio anyway; it is subtracted so the reported BYTE
  totals are true sizes rather than sizes plus a per-row constant.

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
  alias Engram.Repo

  require Logger

  @typedoc """
  One sweep reading. Spelled out rather than `map()` so a measurement added to
  the telemetry event without a matching PromEx gauge fails here.
  """
  @type measurements :: %{
          notes: non_neg_integer(),
          bloat_ratio_p50: float(),
          bloat_ratio_p90: float(),
          bloat_ratio_p99: float(),
          bloat_ratio_max: float(),
          state_bytes_total: non_neg_integer(),
          content_bytes_total: non_neg_integer(),
          notes_over_threshold: non_neg_integer()
        }

  @event [:engram, :crdt, :state_sweep]

  # Matches the `>5x` panel on the engram-crdt dashboard. Changing it here
  # without changing the `le` bucket there makes the two disagree silently.
  @bloat_threshold 5

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if tenancy_unsafe?() do
      Logger.error(
        "crdt_bloat_sweep refusing to run: RLS is enforced and no maintenance pool is " <>
          "configured, so the notes read would return zero rows and the sweep would " <>
          "report an empty database as a healthy one",
        Metadata.with_category(:error, :oban, [])
      )

      {:error, :tenancy_unsafe}
    else
      _ = measure_and_emit()
      :ok
    end
  end

  @doc """
  Run the aggregate and emit `[:engram, :crdt, :state_sweep]`.

  Public so the sweep can be triggered by hand against a real database
  (`Engram.Workers.CrdtBloatSweep.measure_and_emit/0`) without waiting for the
  cron slot. Returns the measurements map.
  """
  @spec measure_and_emit() :: measurements()
  def measure_and_emit do
    measurements = measure()

    :telemetry.execute(@event, measurements, %{})

    Logger.info(
      "crdt_bloat_sweep notes=#{measurements.notes} p50=#{fmt(measurements.bloat_ratio_p50)} " <>
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
          coalesce(percentile_cont(0.5) WITHIN GROUP (ORDER BY ratio), 0)::float8,
          coalesce(percentile_cont(0.9) WITHIN GROUP (ORDER BY ratio), 0)::float8,
          coalesce(percentile_cont(0.99) WITHIN GROUP (ORDER BY ratio), 0)::float8,
          coalesce(max(ratio), 0)::float8,
          coalesce(sum(state_bytes), 0)::bigint,
          coalesce(sum(content_bytes), 0)::bigint,
          count(*) FILTER (WHERE ratio > $2::float8)::bigint
        FROM (
          SELECT
            greatest(octet_length(n.crdt_state_ciphertext) - $1::int, 0) AS state_bytes,
            greatest(octet_length(n.content_ciphertext) - $1::int, 0) AS content_bytes,
            greatest(octet_length(n.crdt_state_ciphertext) - $1::int, 0)::float8
              / greatest(octet_length(n.content_ciphertext) - $1::int, 1)::float8 AS ratio
          FROM notes n
          WHERE n.crdt_state_ciphertext IS NOT NULL
            AND n.deleted_at IS NULL
        ) sized
        """,
        [tag, @bloat_threshold * 1.0]
      )

    [notes, p50, p90, p99, max, state_bytes, content_bytes, over] = row

    %{
      notes: notes,
      bloat_ratio_p50: p50,
      bloat_ratio_p90: p90,
      bloat_ratio_p99: p99,
      bloat_ratio_max: max,
      state_bytes_total: state_bytes,
      content_bytes_total: content_bytes,
      notes_over_threshold: over
    }
  end

  defp tenancy_unsafe? do
    Repo.maintenance() == Repo and Engram.Repo.TenancyGuard.enforced?()
  end

  defp fmt(f) when is_float(f), do: Float.round(f, 2)
end
