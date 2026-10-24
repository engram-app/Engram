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

    * `:missing_local` — Paddle has the subscription, we don't. Excludes
      `canceled` Paddle subs, which a hard-deleted account legitimately
      leaves behind for the length of the reconciliation window.
    * `:status_mismatch` — `paddle.status != local.status`.
    * `:tier_mismatch` — `tier_from_subscription(paddle) != local.tier`.
    * `:period_mismatch` — `paddle.current_billing_period.ends_at` differs
      from `local.current_period_end` by more than `@period_skew_seconds`.
  """

  import Ecto.Query

  alias Engram.Billing.Subscription
  alias Engram.Logger.Metadata
  alias Engram.Repo
  alias Engram.Telemetry

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
          skipped:
            nil
            | :billing_disabled
            | :fetch_failed
            | :max_pages_exceeded
            | :pagination_loop,
          error: nil | term()
        }

  @spec run(pos_integer()) :: result()
  def run(days_back) when is_integer(days_back) and days_back > 0 do
    if Application.get_env(:engram, :billing_enabled, false) do
      do_run(days_back)
    else
      Logger.info(
        "paddle_reconcile_skipped",
        Metadata.with_category(:info, :billing, reason: :billing_disabled)
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
        diff(paddle_subs, nil)

      {:partial, paddle_subs, reason} when reason in [:max_pages_exceeded, :pagination_loop] ->
        # HTTP layer truncated the list (page cap hit or Paddle returned a
        # next URL we'd seen before). Diff what we have but surface the
        # truncation so the Mix task printer doesn't show a clean-looking
        # result — silent-truncation is the exact failure mode this PR
        # exists to surface.
        Logger.error(
          "paddle_reconcile_partial_list",
          Metadata.with_category(:error, :billing, reason_label: reason)
        )

        diff(paddle_subs, reason)

      {:error, reason} ->
        # NEVER inspect(reason) here: a Paddle error is {:paddle_error, status,
        # body} (body is echoed Paddle JSON that can carry customer PII) or a
        # raw Req transport error, and :reason is NOT in RedactFilter's
        # sensitive-key set. Surface only a bounded error_kind + the HTTP status
        # (401 vs 429 vs 500 is the on-call triage signal).
        Logger.error(
          "paddle_reconcile_fetch_failed",
          Metadata.with_category(:error, :billing,
            error_kind: Telemetry.error_kind(reason),
            status: paddle_error_status(reason)
          )
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

  # The HTTP status from a Paddle non-2xx — a bounded integer, safe to log.
  # nil for transport errors (timeout, closed) that have no status.
  defp paddle_error_status({:paddle_error, status, _body}), do: status
  defp paddle_error_status(_), do: nil

  defp diff(paddle_subs, skipped_reason) do
    paddle_ids = Enum.map(paddle_subs, & &1["id"])
    local_subs = local_subscriptions_for(paddle_ids)
    local_by_paddle_id = Map.new(local_subs, &{&1.paddle_subscription_id, &1})

    drift =
      Enum.flat_map(paddle_subs, &classify(&1, local_by_paddle_id))

    log_summary(paddle_subs, local_subs, drift)

    Enum.each(drift, fn entry ->
      Logger.error(
        "paddle_reconciliation_drift",
        Metadata.with_category(:error, :billing,
          drift_kind: entry.kind,
          paddle_subscription_id: entry.subscription_id,
          # The affected customer. nil only for :missing_local (Paddle has a sub
          # we have no local row for) — otherwise it saves a Paddle-dashboard
          # reverse-lookup under incident pressure.
          user_id: entry.user_id
        )
      )
    end)

    %{
      paddle_total: length(paddle_subs),
      local_total: length(local_subs),
      drift: drift,
      skipped: skipped_reason,
      error: nil
    }
  end

  # Look up local rows by the paddle IDs Paddle just returned, NOT by
  # local `updated_at`. Paddle's `updated_at[GTE]` filter happily returns
  # subs whose local row hasn't been touched in months (e.g. Paddle ticks
  # its own `updated_at` for an internal reindex or `scheduled_change`
  # processing). Filtering local by `updated_at` would miss those rows
  # and falsely flag them `:missing_local`. `paddle_subscription_id` is
  # the indexed unique key — bounded by paddle's page cap (`@max_pages *
  # per_page`) and safe to send IN-list.
  defp local_subscriptions_for([]), do: []

  # Spans every tenant, so it reads through the maintenance pool (`maintenance_all`
  # policy): on the app pool with a tenant set, `subscriptions` would hide every
  # other user's row and each paying user would page as `:missing_local` (#1758).
  # `cross_tenant/1` only silences the app tripwire when `maintenance()` falls
  # back to `Repo`; it scopes nothing.
  defp local_subscriptions_for(paddle_ids) do
    Repo.cross_tenant(fn ->
      Repo.maintenance().all(
        from(s in Subscription, where: s.paddle_subscription_id in ^paddle_ids)
      )
    end)
  end

  defp classify(paddle_sub, local_by_id) do
    id = paddle_sub["id"]
    local = Map.get(local_by_id, id)

    cond do
      is_nil(local) and paddle_sub["status"] == "canceled" ->
        # A hard-deleted account cancels its Paddle subscription immediately
        # (Lifecycle.cancel_paddle_subscription/2), then cascade-deletes the
        # local row with the user. Paddle keeps the canceled subscription and
        # ticks its `updated_at` at cancel time, so it re-enters the 7-day
        # window with nothing local to match — and pages nightly for a week
        # (prod, 2026-09-15). Nothing is owed and no entitlement is at stake,
        # so it is not drift. Deliberately narrow: only `canceled`. A
        # `past_due`/`paused`/`active` sub with no local row still pages,
        # which is what catches a hard-delete whose best-effort Paddle cancel
        # failed.
        #
        # Logged at :info, NOT dropped silently. Two reasons. (1) That
        # best-effort cancel failure has a terminal state: we bill a deleted
        # customer while `active` (which pages), then Paddle eventually flips
        # it to `canceled` on its own — dunning exhaustion, a portal cancel,
        # a Paddle-side admin — and this clause would swallow the only
        # remaining trace of a refund we owe. (2) If the skip ever fires at
        # volume, a regression is cascading `subscriptions` rows for users
        # who were never deleted, and a counter that only ever moves on
        # FAILURE would stay flat through it.
        Logger.info(
          "paddle_reconcile_canceled_orphan_skipped",
          Metadata.with_category(:info, :billing,
            paddle_subscription_id: paddle_sub["id"],
            paddle_customer_id: paddle_sub["customer_id"]
          )
        )

        []

      is_nil(local) ->
        [
          %{
            subscription_id: id,
            kind: :missing_local,
            user_id: nil,
            paddle: paddle_sub,
            local: nil
          }
        ]

      paddle_sub["status"] != local.status ->
        [
          %{
            subscription_id: id,
            kind: :status_mismatch,
            user_id: local.user_id,
            paddle: paddle_sub["status"],
            local: local.status
          }
        ]

      paddle_tier_string(paddle_sub) != local.tier ->
        [
          %{
            subscription_id: id,
            kind: :tier_mismatch,
            user_id: local.user_id,
            paddle: Engram.Billing.tier_from_subscription(paddle_sub),
            local: local.tier
          }
        ]

      missing_local_period?(paddle_sub, local) ->
        repair_period_end(paddle_sub, local)
        []

      period_mismatch?(paddle_sub, local) ->
        [
          %{
            subscription_id: id,
            kind: :period_mismatch,
            user_id: local.user_id,
            paddle: get_in(paddle_sub, ["current_billing_period", "ends_at"]),
            local: local.current_period_end
          }
        ]

      true ->
        []
    end
  end

  # Resolve a Paddle subscription's tier into a string comparable to the
  # local subscription's `tier` column. Unknown price IDs surface as
  # `nil`, which `tier_mismatch` then flags vs the local tier (the
  # `paddle:` payload still carries the full `{:error, :unknown_price_id}`
  # tuple so operators can see WHY).
  defp paddle_tier_string(paddle_sub) do
    case Engram.Billing.tier_from_subscription(paddle_sub) do
      {:ok, tier} -> Atom.to_string(tier)
      {:error, :unknown_price_id} -> nil
    end
  end

  # Paddle sends `current_billing_period: null` once a subscription is canceled
  # or paused: there is no period to compare, and access is gated on the status
  # (already matched above), not on a stale local period end. Paddle's side goes
  # through the parser the webhook path writes with. Only a NON-nil `ends_at`
  # that fails to parse is a contract change worth a warning.
  defp period_mismatch?(paddle_sub, local) do
    case {Engram.Billing.parse_period_end(paddle_sub), local.current_period_end} do
      {%DateTime{} = paddle_dt, %DateTime{} = local_dt} ->
        abs(DateTime.diff(paddle_dt, local_dt, :second)) > @period_skew_seconds

      {nil, _local} ->
        warn_if_unparseable(paddle_sub)
        false

      # {live Paddle period, nil local} is repaired in classify/2 before here.
      _ ->
        false
    end
  end

  defp warn_if_unparseable(paddle_sub) do
    case paddle_sub["current_billing_period"] do
      %{"ends_at" => nil} ->
        :ok

      %{"ends_at" => ends_at} ->
        Logger.warning(
          "paddle_reconcile_period_unparseable",
          Metadata.with_category(:warning, :billing,
            paddle_subscription_id: paddle_sub["id"],
            reason: inspect(ends_at)
          )
        )

      _ ->
        :ok
    end
  end

  # Paddle has a live period and our mirror stored none (a webhook that
  # carried no period, then nothing since). Paddle is ground truth for this
  # field, so copy it over instead of paging the same drift every night.
  defp missing_local_period?(paddle_sub, local) do
    is_nil(local.current_period_end) and
      match?(%DateTime{}, Engram.Billing.parse_period_end(paddle_sub))
  end

  defp repair_period_end(paddle_sub, local) do
    period_end = Engram.Billing.parse_period_end(paddle_sub)

    # Written under the owner's tenant, like the webhook mirror (#1758). By id
    # with update_all, not update!: a row hard-deleted since the read (an
    # account delete racing the run) updates nothing instead of raising and
    # killing the rest of the diff.
    Repo.with_tenant!(local.user_id, fn ->
      Repo.update_all(from(s in Subscription, where: s.id == ^local.id),
        set: [current_period_end: period_end]
      )
    end)

    Logger.info(
      "paddle_reconcile_period_repaired",
      Metadata.with_category(:info, :billing,
        paddle_subscription_id: paddle_sub["id"],
        user_id: local.user_id
      )
    )
  end

  # A payment parked at `action_required` this long is a stalled checkout,
  # not a 3DS challenge still in progress (the alert's own grace period).
  @stalled_after_seconds 15 * 60
  # The scan's cron interval (config.exs `4-59/5`): each run owns exactly one
  # window of this width, so the windows tile. Pinned against the crontab by
  # paddle_reconcile_test.exs. 5 min, not 15: with the grace that puts the
  # worst-case report at 20 min after the attempt, not 30 (#2203).
  @stalled_scan_window_seconds 5 * 60

  @doc "Width of one stalled-scan window, equal to the scan's cron interval."
  @spec stalled_scan_window_seconds() :: 300
  def stalled_scan_window_seconds, do: @stalled_scan_window_seconds

  @doc """
  Reports `ready` Paddle transactions whose newest payment parked at
  `action_required` (3DS / wallet approval) and never moved on. Paddle sends
  no webhook for that state, so without this scan engram-infra #1157's
  stalled-checkout alert never sees the line it needs.

  Dedupe without state: a run anchored at `anchor` (its cron tick, to the
  minute) owns payments created in `[anchor - 20m, anchor - 15m)`. Consecutive ticks
  tile the timeline, so each stalled payment is reported by exactly one run,
  and a retry of the same job (same anchor) re-reads the same window.
  ponytail: a tick that never runs (whole cluster down) skips its window; a
  persisted cursor would close that gap if it ever matters.

  Returns the number of transactions reported, or `{:error, reason}`.
  """
  @spec report_stalled_checkouts(DateTime.t()) :: non_neg_integer() | {:error, :fetch_failed}
  def report_stalled_checkouts(%DateTime{} = anchor) do
    if Application.get_env(:engram, :billing_enabled, false) do
      window_end = DateTime.add(anchor, -@stalled_after_seconds, :second)
      window_start = DateTime.add(window_end, -@stalled_scan_window_seconds, :second)

      case Engram.Paddle.Client.impl().list_ready_transactions(window_start) do
        {:ok, txns} ->
          report_stalled(txns, window_start, window_end)

        {:partial, txns, _reason} ->
          report_stalled(txns, window_start, window_end)

        {:error, reason} ->
          # Bounded fields only, same reason as `paddle_reconcile_fetch_failed`.
          Logger.error(
            "paddle_stalled_scan_fetch_failed",
            Metadata.with_category(:error, :billing,
              error_kind: Telemetry.error_kind(reason),
              status: paddle_error_status(reason)
            )
          )

          {:error, :fetch_failed}
      end
    else
      0
    end
  end

  defp report_stalled(txns, window_start, window_end) do
    txns
    |> Enum.filter(&stalled_in_window?(&1, window_start, window_end))
    |> Enum.count(fn txn ->
      Engram.Billing.report_checkout_transaction("reconcile.stalled_scan", txn) ==
        {:ok, :checkout_stalled}
    end)
  end

  defp stalled_in_window?(txn, window_start, window_end) do
    with %{"status" => "action_required", "created_at" => created} <-
           Engram.Billing.newest_payment(List.wrap(txn["payments"])),
         {:ok, created_at, _} <- DateTime.from_iso8601(created) do
      DateTime.compare(created_at, window_start) != :lt and
        DateTime.compare(created_at, window_end) == :lt
    else
      _ -> false
    end
  end

  defp log_summary(paddle, local, drift) do
    Logger.info(
      "paddle_reconcile_summary paddle=#{length(paddle)} local=#{length(local)} drift=#{length(drift)}",
      Metadata.with_category(:info, :billing, [])
    )
  end
end
