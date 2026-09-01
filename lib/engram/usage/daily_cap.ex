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
        # Short-circuit deny: a known-empty bucket never touched the DB.
        emit(kind, :deny)
        {:deny, retry_after_sec}

      :unknown ->
        do_spend(user_id, kind, capacity, refill_per_sec)
    end
  end

  @doc """
  Tokens left in a bucket, WITHOUT spending one.

  Read-only mirror of `spend/4`'s refill arithmetic, for surfacing "you have N
  searches left today" in the UI. Deliberately not routed through `spend/4`:
  asking how much budget you have must not consume budget.

  A user who has never spent has no row, which is not the same as an empty
  bucket — it means full capacity. Fails OPEN on a DB error, same as `spend/4`:
  an advisory number is never worth a 500.
  """
  # Module attribute, not a local binding, for the same reason `@sql` below is
  # one: sobelow's SQL.Query check cannot prove a variable passed to
  # `Repo.query/2` is constant and flags it as injection. Both are fully
  # parameterized; keeping the shape identical to its sibling keeps the finding
  # from existing rather than suppressing it in `.sobelow-skips`.
  @remaining_sql """
  SELECT LEAST($3::float,
           tokens + GREATEST(0, EXTRACT(EPOCH FROM (now() - last_refill_at))) * $4::float)
    FROM usage_buckets
   WHERE user_id = $1::uuid AND kind = $2
  """

  @spec remaining(binary(), String.t(), pos_integer(), float()) :: float()
  def remaining(user_id, kind, capacity, refill_per_sec) do
    case Cache.empty_until(user_id, kind) do
      # `spend/4` consults this cache FIRST and short-circuits a deny without
      # touching the DB, and `mark_empty/3` caches for a fixed
      # `ceil(1/refill_per_sec)` regardless of the actual fractional deficit.
      # Reading Postgres directly would therefore report "1 search left" for
      # most of a window in which `spend/4` still refuses — an advisory number
      # that contradicts the authority is worse than no number.
      {:empty, _retry} -> 0.0
      :unknown -> do_remaining(user_id, kind, capacity, refill_per_sec)
    end
  end

  defp do_remaining(user_id, kind, capacity, refill_per_sec) do
    case Repo.query(@remaining_sql, [
           Ecto.UUID.dump!(user_id),
           kind,
           capacity * 1.0,
           refill_per_sec
         ]) do
      {:ok, %{rows: [[tokens]]}} ->
        max(0.0, tokens)

      # No row is not an empty bucket — it means nothing has been spent yet.
      {:ok, %{rows: []}} ->
        capacity * 1.0

      {:error, reason} ->
        # Same fail-open as `do_spend/4`, and logged + emitted for the same
        # reason: a fabricated number with no signal is indistinguishable from
        # a real one. `emit/2` feeds `Engram.PromEx.Usage`.
        Logger.warning(
          "daily_cap remaining fail-open",
          Engram.Logger.Metadata.with_category(:warning, :billing,
            kind: kind,
            reason: inspect(reason)
          )
        )

        emit(kind, :fail_open)
        capacity * 1.0
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
        emit(kind, :allow)
        {:allow, tokens}

      {:ok, %{rows: []}} ->
        # WHERE failed → under 1 token. Cache the empty verdict until ~1 token
        # regenerates, so subsequent requests skip the DB.
        retry = if refill_per_sec > 0, do: ceil(1 / refill_per_sec), else: 3600
        Cache.mark_empty(user_id, kind, retry)
        emit(kind, :deny)
        {:deny, retry}

      {:error, reason} ->
        Logger.warning(
          "daily_cap fail-open",
          Engram.Logger.Metadata.with_category(:warning, :billing,
            kind: kind,
            reason: inspect(reason)
          )
        )

        emit(kind, :fail_open)
        {:allow, 0.0}
    end
  end

  # Allow/deny/fail-open visibility for the daily cap. `kind` is a fixed
  # bucket label (e.g. "inapp_search") — safe to tag (low cardinality);
  # never user_id. Picked up by `Engram.PromEx.Usage`.
  @spec emit(String.t(), :allow | :deny | :fail_open) :: :ok
  defp emit(kind, decision) do
    :telemetry.execute(
      [:engram, :usage, :daily_cap],
      %{count: 1},
      %{kind: kind, decision: decision}
    )
  end
end
