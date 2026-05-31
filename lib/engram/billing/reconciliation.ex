defmodule Engram.Billing.Reconciliation do
  @moduledoc """
  Diff Paddle subscription state against the local `subscriptions` table.

  Ground truth: Paddle. Anything Paddle has that we don't (or vice versa,
  or a field that disagrees) is drift. Drift gets logged at `:error`
  level so Sentry's LoggerHandler captures it. Returns a summary map;
  does not raise.

  Self-host (`:billing_enabled` config false) short-circuits to a no-op
  so the Oban cron is harmless when Paddle isn't wired.

  Drift kinds:

    * `:missing_local` — Paddle has the subscription, we don't.
    * `:status_mismatch` — `paddle.status != local.status`.
    * `:tier_mismatch` — `tier_from_subscription(paddle) != local.tier`.
    * `:period_mismatch` — `paddle.current_billing_period.ends_at` differs
      from `local.current_period_end` by more than `@period_skew_seconds`.
  """

  import Ecto.Query

  alias Engram.Billing.Subscription
  alias Engram.Repo

  require Logger

  # 2-minute tolerance covers NTP drift + Paddle → webhook → DB write
  # propagation (parse_period_end/1 also truncates to seconds). Tighter
  # values produced false-positive period_mismatch entries during
  # sandbox smoke testing 2026-05-23.
  @period_skew_seconds 120

  @type drift_kind ::
          :missing_local | :status_mismatch | :tier_mismatch | :period_mismatch

  @type drift_entry :: %{
          subscription_id: String.t(),
          kind: drift_kind(),
          paddle: term(),
          local: term() | nil
        }

  @type result :: %{
          paddle_total: non_neg_integer(),
          local_total: non_neg_integer(),
          drift: [drift_entry()],
          skipped: nil | :billing_disabled | :fetch_failed,
          error: nil | term()
        }

  @spec run(pos_integer()) :: result()
  def run(days_back) when is_integer(days_back) and days_back > 0 do
    if Application.get_env(:engram, :billing_enabled, false) do
      do_run(days_back)
    else
      Logger.info("paddle_reconcile_skipped",
        category: :paddle_reconcile,
        reason: :billing_disabled
      )

      %{
        paddle_total: 0,
        local_total: 0,
        drift: [],
        skipped: :billing_disabled,
        error: nil
      }
    end
  end

  defp do_run(days_back) do
    since = DateTime.utc_now() |> DateTime.add(-days_back * 86_400, :second)

    case Engram.Paddle.Client.impl().list_subscriptions(since) do
      {:ok, paddle_subs} ->
        local_subs = recent_local_subscriptions(since)
        local_by_paddle_id = Map.new(local_subs, &{&1.paddle_subscription_id, &1})

        drift =
          Enum.flat_map(paddle_subs, &classify(&1, local_by_paddle_id))

        log_summary(paddle_subs, local_subs, drift)

        Enum.each(drift, fn entry ->
          Logger.error("paddle_reconciliation_drift",
            category: :paddle_reconcile,
            drift_kind: entry.kind,
            paddle_subscription_id: entry.subscription_id
          )
        end)

        %{
          paddle_total: length(paddle_subs),
          local_total: length(local_subs),
          drift: drift,
          skipped: nil,
          error: nil
        }

      {:error, reason} ->
        Logger.error("paddle_reconcile_fetch_failed",
          category: :paddle_reconcile,
          reason: inspect(reason)
        )

        # Distinguish a fetch failure from a clean run in the return
        # shape so the Mix task printer + future callers can branch.
        # Without this, drift: [] + paddle_total: 0 looks identical to
        # 'Paddle has no recently-updated subs' to a half-asleep on-call.
        %{
          paddle_total: 0,
          local_total: 0,
          drift: [],
          skipped: :fetch_failed,
          error: reason
        }
    end
  end

  defp recent_local_subscriptions(since) do
    from(s in Subscription, where: s.updated_at >= ^since)
    |> Repo.all(skip_tenant_check: true)
  end

  defp classify(paddle_sub, local_by_id) do
    id = paddle_sub["id"]
    local = Map.get(local_by_id, id)

    cond do
      is_nil(local) ->
        [%{subscription_id: id, kind: :missing_local, paddle: paddle_sub, local: nil}]

      paddle_sub["status"] != local.status ->
        [
          %{
            subscription_id: id,
            kind: :status_mismatch,
            paddle: paddle_sub["status"],
            local: local.status
          }
        ]

      Engram.Billing.tier_from_subscription(paddle_sub) != local.tier ->
        [
          %{
            subscription_id: id,
            kind: :tier_mismatch,
            paddle: Engram.Billing.tier_from_subscription(paddle_sub),
            local: local.tier
          }
        ]

      period_mismatch?(paddle_sub, local) ->
        [
          %{
            subscription_id: id,
            kind: :period_mismatch,
            paddle: get_in(paddle_sub, ["current_billing_period", "ends_at"]),
            local: local.current_period_end
          }
        ]

      true ->
        []
    end
  end

  defp period_mismatch?(paddle_sub, local) do
    with %{"ends_at" => ts} <- paddle_sub["current_billing_period"],
         {:ok, paddle_dt, _offset} <- DateTime.from_iso8601(ts),
         %DateTime{} = local_dt <- local.current_period_end do
      abs(DateTime.diff(paddle_dt, local_dt, :second)) > @period_skew_seconds
    else
      other ->
        # Couldn't parse — treat as no-drift to avoid spamming Sentry
        # on every reconciliation cycle when Paddle returns an
        # unexpected shape, but warn so a contract change is visible.
        Logger.warning("paddle_reconcile_period_unparseable",
          category: :paddle_reconcile,
          paddle_subscription_id: paddle_sub["id"],
          reason: inspect(other)
        )

        false
    end
  end

  defp log_summary(paddle, local, drift) do
    Logger.info(
      "paddle_reconcile_summary paddle=#{length(paddle)} local=#{length(local)} drift=#{length(drift)}",
      category: :paddle_reconcile
    )
  end
end
