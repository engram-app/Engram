defmodule Engram.EmbedCeiling do
  @moduledoc """
  The per-user daily embed token ceiling: Voyage index tokens one user may
  spend per UTC day (`embed_tokens_per_day`, 20M by default on every tier).

  Before it, a paid account had no spend ceiling at all, so a runaway writer
  (an agent rewriting a big note in a loop) could cost hundreds of dollars a
  day with nothing to stop it. Over the ceiling nothing is refused or lost:

    * an embed pass runs keyword-only and the note parks on the same queue the
      Free bucket uses (`embed_budget_parked`, so the reconcile sweep's due
      index skips it); the write itself is never touched;
    * a note the sweep hands back while the day is still spent parks again
      without a pass (`EmbedNote` checks `available/2` first);
    * search skips the query embed and runs keyword-only (`Engram.Search`);
    * the user's wake (`Engram.Workers.WakeBudgetParked`) is scheduled at the
      next 00:00 UTC plus a fixed per-user offset spread over six hours
      (`resume_at/2`), and wakes what fits the new day oldest first, in pages
      of 500 a minute apart, at backfill priority.

  Who it binds: users whose `embed_token_bucket` is nil (paid). "Unlimited"
  means unlimited in one place: a `-1` (or self-host `:unlimited`) embed
  bucket exempts the user from the ceiling too, and so does a `-1`
  `embed_tokens_per_day` override. Free is bounded by its bucket, whose 6M
  capacity is below the ceiling. Kill switch: the `embed_daily_ceiling`
  ServiceConfig override, default on. Off (or a lifted ceiling) uncaps new
  passes at once; notes already parked wake on the sweep's backstop (every
  3 h), not instantly.

  Spent means fewer than `floor/0` tokens left (one full chunk): below that a
  pass could only embed nothing and re-park, so it is not run.

  Query embeds do NOT count toward the ceiling: each is a few dozen tokens on
  the cheap query model, already bounded per user by the MCP and API rate
  limits (and by `ai_searches_per_day` on Free), and counting them would put
  a write on every search. Over the ceiling they stop anyway, because search
  goes keyword-only. Cost: one `usage_meters` primary-key read per search of
  a user with a ceiling.

  State: `usage_meters.embed_day` / `embed_day_tokens`, one row per user
  (`Engram.UsageMeters.day_take/4`): O(1) per check, atomic across nodes,
  and kept across deploys.
  """

  alias Engram.Billing
  alias Engram.Logger.Metadata
  alias Engram.Parsers.Markdown
  alias Engram.ServiceConfig
  alias Engram.UsageMeters

  require Logger

  # Each user's parked work comes due within this long after 00:00 UTC.
  @resume_spread_seconds 6 * 3_600

  @doc "False when the `embed_daily_ceiling` ServiceConfig switch is off."
  @spec enabled?() :: boolean()
  def enabled?, do: ServiceConfig.get(:embed_daily_ceiling, true) == true

  @doc "Tokens one full chunk can cost: less than this left is a spent day."
  @spec floor() :: pos_integer()
  def floor, do: UsageMeters.estimate_tokens(Markdown.max_chunk())

  @doc """
  The user's ceiling in tokens, or nil when none applies: the switch off, a
  Free bucket, an unlimited bucket (`-1` override, self-host), or an unlimited
  or malformed `embed_tokens_per_day`. A malformed bucket keeps its own
  fail-closed path.
  """
  @spec tokens(map()) :: non_neg_integer() | nil
  def tokens(user) do
    with true <- enabled?(),
         nil <- Billing.effective_limit(user, :embed_token_bucket),
         n when is_integer(n) and n >= 0 <- Billing.effective_limit(user, :embed_tokens_per_day) do
      n
    else
      _ -> nil
    end
  end

  @doc "Tokens left today under `ceiling`; 0 once fewer than `floor/0` are."
  @spec available(Ecto.UUID.t(), non_neg_integer()) :: non_neg_integer()
  def available(user_id, ceiling) do
    case ceiling - UsageMeters.day_used(user_id) do
      left when is_integer(left) and left >= 0 ->
        if left < min(floor(), ceiling), do: 0, else: left

      _over ->
        0
    end
  end

  @doc """
  True when the user has a ceiling and has spent today's (see `available/2`).
  For search: one `usage_meters` primary-key read, none when no ceiling applies.
  """
  @spec over?(map()) :: boolean()
  def over?(user) do
    case tokens(user) do
      nil -> false
      ceiling -> available(user.id, ceiling) == 0
    end
  end

  @doc """
  When a user's ceiling-parked notes wake: the next 00:00 UTC plus a fixed
  per-user offset under six hours, so users do not all resume at once.
  """
  @spec resume_at(Ecto.UUID.t(), DateTime.t()) :: DateTime.t()
  def resume_at(user_id, now \\ DateTime.utc_now()) do
    midnight = DateTime.new!(Date.add(DateTime.to_date(now), 1), ~T[00:00:00], "Etc/UTC")
    DateTime.add(midnight, :erlang.phash2(user_id, @resume_spread_seconds), :second)
  end

  @doc """
  A pass parked on the ceiling. Always counts the park
  (`[:engram, :embed, :ceiling_parked]`); the first park of a user's UTC day
  also logs one warning, emits `[:engram, :abuse, :embed_ceiling_hit]` and
  reports a silent limit hit to product analytics.
  """
  @spec parked(map(), non_neg_integer()) :: :ok
  def parked(%{id: user_id} = user, ceiling) do
    :telemetry.execute([:engram, :embed, :ceiling_parked], %{count: 1}, %{})
    key = "embed_ceiling_hit:#{user_id}:#{Date.utc_today()}"

    # Cluster-synced, not persisted: a deploy mid-day can log the same
    # user-day once more, which is the price of not writing a row for it.
    case EngramWeb.RateLimiter.hit(key, :timer.hours(24), 1, :voyage_embed) do
      {:allow, _} -> first_hit(user, ceiling)
      _deny -> :ok
    end
  end

  defp first_hit(%{id: user_id} = user, ceiling) do
    :telemetry.execute([:engram, :abuse, :embed_ceiling_hit], %{count: 1}, %{})

    Engram.Analytics.track_limit_hit(
      user,
      :embed_tokens_per_day,
      %{silent: true},
      :timer.hours(24)
    )

    Logger.warning(
      "EmbedNote indexing keyword-only until the next UTC day, daily embed ceiling reached",
      Metadata.with_category(:warning, :billing,
        user_id: user_id,
        reason_label: :embed_daily_ceiling,
        cap: ceiling
      )
    )

    :ok
  end

  @doc """
  Today's fleet numbers for the PromEx poll: the most one user spent, that as
  a share of the default ceiling, and the users whose day is spent (within
  `floor/0` of it, as `available/2` reads it). nil when the ceiling is off or
  limits are not enforced (self-host). Per-user overrides are not read here:
  the share is against the Pro default.
  """
  @spec stats() :: %{max: non_neg_integer(), share: float(), over: non_neg_integer()} | nil
  def stats do
    with true <- enabled?(),
         ceiling when is_integer(ceiling) and ceiling > 0 <-
           Billing.tier_cap(:pro, :embed_tokens_per_day) do
      %{max: max, over: over} = UsageMeters.day_stats(max(ceiling - floor() + 1, 1))
      %{max: max, share: max / ceiling, over: over}
    else
      _ -> nil
    end
  end
end
