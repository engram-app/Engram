defmodule Engram.EmbedCeiling do
  @moduledoc """
  The per-user daily embed token ceiling: Voyage index tokens one user may
  spend per UTC day (`embed_tokens_per_day`, 20M by default on every tier).

  Before it, a paid account had no spend ceiling at all, so a runaway writer
  (an agent rewriting a big note in a loop) could cost hundreds of dollars a
  day with nothing to stop it. Over the ceiling nothing is refused or lost:

    * an embed pass runs keyword-only and the note parks until the next UTC
      day (`EmbedNote`); the write itself is never touched;
    * search skips the query embed and runs keyword-only (`Engram.Search`);
    * at the day's turn each user's parked notes come due at midnight plus a
      fixed per-user offset (`resume_at/2`, spread over an hour), and
      `ReconcileEmbeddings` re-embeds them at its usual per-tick pace, so the
      catch-up is never one burst.

  Who it binds: users with no Free bucket (`embed_token_bucket` nil or -1).
  Free is bounded by its bucket, whose 6M capacity is below the ceiling.
  Self-host (limits not enforced) and a `-1` per-user override (our staging
  accounts) are never capped. Kill switch: the `embed_daily_ceiling`
  ServiceConfig override, default on; off restores the uncapped behaviour.

  Query embeds do NOT count toward the ceiling: each is a few dozen tokens on
  the cheap query model, already bounded per user by the MCP and API rate
  limits (and by `ai_searches_per_day` on Free), and counting them would put
  a write on every search. Over the ceiling they stop anyway, because search
  goes keyword-only.

  State: `usage_meters.embed_day` / `embed_day_tokens`, one row per user
  (`Engram.UsageMeters.day_take/4`): O(1) per check, atomic across nodes,
  and kept across deploys.
  """

  alias Engram.Billing
  alias Engram.Logger.Metadata
  alias Engram.ServiceConfig
  alias Engram.UsageMeters

  require Logger

  # Each user's parked work comes due within this long after 00:00 UTC.
  @resume_spread_seconds 3_600

  @doc "False when the `embed_daily_ceiling` ServiceConfig switch is off."
  @spec enabled?() :: boolean()
  def enabled?, do: ServiceConfig.get(:embed_daily_ceiling, true) == true

  @doc """
  The user's ceiling in tokens, or nil when none applies (switch off, a Free
  bucket user, self-host, or an unlimited override). A malformed override
  reads as nil: the bucket path already fails closed on its own malformed
  value, and a wrong ceiling must not stop a paying user's embeds.
  """
  @spec tokens(map()) :: non_neg_integer() | nil
  def tokens(user) do
    if enabled?() and not bucket?(user) do
      case Billing.effective_limit(user, :embed_tokens_per_day) do
        n when is_integer(n) and n >= 0 -> n
        _ -> nil
      end
    end
  end

  # A malformed bucket override counts as a bucket: that path fails closed
  # on it, as it always has.
  defp bucket?(user) do
    case Billing.effective_limit(user, :embed_token_bucket) do
      cap when cap in [nil, :unlimited] -> false
      cap when is_integer(cap) and cap < 0 -> false
      _ -> true
    end
  end

  @doc "Tokens left today under `ceiling`."
  @spec available(Ecto.UUID.t(), non_neg_integer()) :: non_neg_integer()
  def available(user_id, ceiling), do: max(ceiling - UsageMeters.day_used(user_id), 0)

  @doc """
  True when the user has a ceiling and has spent all of it today. For search:
  one `usage_meters` primary-key read, and none when no ceiling applies.
  """
  @spec over?(map()) :: boolean()
  def over?(user) do
    case tokens(user) do
      nil -> false
      ceiling -> available(user.id, ceiling) == 0
    end
  end

  @doc """
  When a note parked on the ceiling comes due again: the next 00:00 UTC plus
  a fixed per-user offset under an hour, so users do not all resume at once.
  """
  @spec resume_at(Ecto.UUID.t(), DateTime.t()) :: DateTime.t()
  def resume_at(user_id, now \\ DateTime.utc_now()) do
    midnight = DateTime.new!(Date.add(DateTime.to_date(now), 1), ~T[00:00:00], "Etc/UTC")
    DateTime.add(midnight, :erlang.phash2(user_id, @resume_spread_seconds), :second)
  end

  @doc """
  A pass parked on the ceiling. Always counts the park
  (`[:engram, :embed, :ceiling_parked]`); the first park of a user's UTC day
  also logs one warning and emits `[:engram, :abuse, :embed_ceiling_hit]`.
  """
  @spec parked(map(), non_neg_integer()) :: :ok
  def parked(%{id: user_id}, ceiling) do
    :telemetry.execute([:engram, :embed, :ceiling_parked], %{count: 1}, %{})
    key = "embed_ceiling_hit:#{user_id}:#{Date.utc_today()}"

    # Cluster-synced, not persisted: a deploy mid-day can log the same
    # user-day once more, which is the price of not writing a row for it.
    case EngramWeb.RateLimiter.hit(key, :timer.hours(24), 1) do
      {:allow, _} -> first_hit(user_id, ceiling)
      _deny -> :ok
    end
  end

  defp first_hit(user_id, ceiling) do
    :telemetry.execute([:engram, :abuse, :embed_ceiling_hit], %{count: 1}, %{})

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
  a share of the default ceiling, and the users at or over it. nil when the
  ceiling is off or limits are not enforced (self-host). Per-user overrides
  are not read here: the share is against the Pro default.
  """
  @spec stats() :: %{max: non_neg_integer(), share: float(), over: non_neg_integer()} | nil
  def stats do
    with true <- enabled?(),
         ceiling when is_integer(ceiling) and ceiling > 0 <-
           Billing.tier_cap(:pro, :embed_tokens_per_day) do
      %{max: max, over: over} = UsageMeters.day_stats(ceiling)
      %{max: max, share: max / ceiling, over: over}
    else
      _ -> nil
    end
  end
end
