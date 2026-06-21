defmodule Engram.Usage.DailyCap do
  @moduledoc """
  Lazy-refill token bucket, authoritative in Postgres (`usage_buckets`),
  durable across deploys. One atomic SQL statement does refill + spend +
  clamp, so the count is exact regardless of node count. `Cache` short-
  circuits known-empty buckets so a capped user gets an instant deny with
  zero DB round-trips. On any DB error the call **fails open** (allow) —
  availability beats enforcement during an outage.

  `capacity` is the max burst (= the plan's daily allowance), `refill_per_sec`
  is the sustained rate (allowance / 86_400). There is no reset event — tokens
  regenerate continuously from `last_refill_at`, so there is no cron.
  """
  alias Engram.Repo
  alias Engram.Usage.DailyCap.Cache

  require Logger

  @type result :: {:allow, float()} | {:deny, non_neg_integer()}

  @spec spend(binary(), String.t(), pos_integer(), float()) :: result()
  def spend(user_id, kind, capacity, refill_per_sec) do
    case Cache.empty_until(user_id, kind) do
      {:empty, retry_after_sec} ->
        {:deny, retry_after_sec}

      :unknown ->
        do_spend(user_id, kind, capacity, refill_per_sec)
    end
  end

  # GREATEST(0, …) guards a clock that moved backward. now() is the single DB
  # clock, so cross-node skew is irrelevant. RETURNING tokens lets us decide.
  @sql """
  INSERT INTO usage_buckets (user_id, kind, tokens, last_refill_at)
  VALUES ($1::uuid, $2, $3::float - 1, now())
  ON CONFLICT (user_id, kind) DO UPDATE SET
    tokens = LEAST($3::float,
      usage_buckets.tokens
      + GREATEST(0, EXTRACT(EPOCH FROM (now() - usage_buckets.last_refill_at))) * $4::float) - 1,
    last_refill_at = now()
  WHERE LEAST($3::float,
      usage_buckets.tokens
      + GREATEST(0, EXTRACT(EPOCH FROM (now() - usage_buckets.last_refill_at))) * $4::float) >= 1
  RETURNING tokens
  """

  defp do_spend(user_id, kind, capacity, refill_per_sec) do
    user_id_bin = Ecto.UUID.dump!(user_id)

    case Repo.query(@sql, [user_id_bin, kind, capacity * 1.0, refill_per_sec]) do
      {:ok, %{rows: [[tokens]]}} ->
        {:allow, tokens}

      {:ok, %{rows: []}} ->
        # WHERE failed → under 1 token. Cache the empty verdict until ~1 token
        # regenerates, so subsequent requests skip the DB.
        retry = if refill_per_sec > 0, do: ceil(1 / refill_per_sec), else: 3600
        Cache.mark_empty(user_id, kind, retry)
        {:deny, retry}

      {:error, reason} ->
        Logger.warning("daily_cap fail-open", kind: kind, reason: inspect(reason))
        {:allow, 0.0}
    end
  end
end
