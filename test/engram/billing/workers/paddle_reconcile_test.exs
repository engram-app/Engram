defmodule Engram.Billing.Workers.PaddleReconcileTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox

  alias Engram.Billing.Workers.PaddleReconcile

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    original = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)
    on_exit(fn -> Application.put_env(:engram, :billing_enabled, original) end)
    :ok
  end

  test "perform/1 calls Reconciliation.run/1 and returns :ok" do
    Engram.Paddle.ClientMock
    |> expect(:list_subscriptions, fn _since -> {:ok, []} end)

    assert :ok = perform_job(PaddleReconcile, %{})
  end

  test "perform/1 emits [:engram, :paddle, :reconcile, :run] with outcome tag" do
    ref =
      :telemetry_test.attach_event_handlers(
        self(),
        [[:engram, :paddle, :reconcile, :run]]
      )

    Engram.Paddle.ClientMock
    |> expect(:list_subscriptions, fn _since -> {:ok, []} end)

    assert :ok = perform_job(PaddleReconcile, %{})

    assert_received {[:engram, :paddle, :reconcile, :run], ^ref,
                     %{paddle_total: 0, drift_count: 0}, %{outcome: :ok}}
  end

  test "perform/1 surfaces :partial outcome via telemetry" do
    ref =
      :telemetry_test.attach_event_handlers(
        self(),
        [[:engram, :paddle, :reconcile, :run]]
      )

    Engram.Paddle.ClientMock
    |> expect(:list_subscriptions, fn _since -> {:partial, [], :max_pages_exceeded} end)

    assert :ok = perform_job(PaddleReconcile, %{})

    assert_received {[:engram, :paddle, :reconcile, :run], ^ref, _,
                     %{outcome: :max_pages_exceeded}}
  end

  test "perform/1 returns :ok even when drift is detected (drift is signal, not failure)" do
    Engram.Paddle.ClientMock
    |> expect(:list_subscriptions, fn _since ->
      {:ok,
       [
         %{
           "id" => "sub_ghost",
           "status" => "active",
           "customer_id" => "ctm_ghost",
           "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
           "current_billing_period" => %{"ends_at" => "2026-06-30T00:00:00Z"}
         }
       ]}
    end)

    assert :ok = perform_job(PaddleReconcile, %{})
  end

  describe "stalled-checkout scan" do
    alias Engram.Billing.Reconciliation

    # Tick 12:00 owns payments created in [11:40, 11:45): 15 to 20 minutes old.
    @anchor ~U[2026-10-23 12:00:00Z]

    defp txn(id, payments, extra \\ %{}) do
      Map.merge(
        %{
          "id" => id,
          "status" => "ready",
          "origin" => "web",
          "customer_id" => "ctm_1",
          "payments" => payments
        },
        extra
      )
    end

    defp payment(status, created_at),
      do: %{
        "status" => status,
        "created_at" => created_at,
        "method_details" => %{"type" => "apple_pay"}
      }

    defp stalled_events do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:engram, :paddle, :checkout, :stalled]])

      ref
    end

    test "reports a ready transaction parked at action_required 15+ minutes, once per window" do
      ref = stalled_events()

      Engram.Paddle.ClientMock
      |> expect(:list_ready_transactions, fn since ->
        assert since == ~U[2026-10-23 11:40:00Z]

        {:ok,
         [
           txn("txn_stalled", [payment("action_required", "2026-10-23T11:42:00Z")]),
           # Newer than 15 min: a 3DS challenge still in progress.
           txn("txn_fresh", [payment("action_required", "2026-10-23T11:50:00Z")]),
           # Older than the window: the previous tick already reported it.
           txn("txn_prev_window", [payment("action_required", "2026-10-23T11:36:00Z")]),
           # Newest attempt is a capture in flight, not a stall.
           txn("txn_retried", [
             payment("action_required", "2026-10-23T11:41:00Z"),
             payment("authorized", "2026-10-23T11:43:00Z")
           ]),
           # Renewal: dunning, owned by subscription.past_due.
           txn("txn_renewal", [payment("action_required", "2026-10-23T11:42:00Z")], %{
             "origin" => "subscription_recurring"
           }),
           txn("txn_no_payments", [])
         ]}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Reconciliation.report_stalled_checkouts(@anchor) == 1
        end)

      assert log =~ "checkout_payment_action_required"

      assert_received {[:engram, :paddle, :checkout, :stalled], ^ref, %{count: 1},
                       %{reason: :action_required}}

      refute_received {[:engram, :paddle, :checkout, :stalled], ^ref, _, _}
    end

    test "the next tick does not re-report the same transaction" do
      Engram.Paddle.ClientMock
      |> expect(:list_ready_transactions, fn _since ->
        {:ok, [txn("txn_stalled", [payment("action_required", "2026-10-23T11:42:00Z")])]}
      end)

      assert Reconciliation.report_stalled_checkouts(DateTime.add(@anchor, 300, :second)) == 0
    end

    # Half-open [anchor - 20m, anchor - 15m): an attempt exactly on a boundary
    # belongs to exactly one tick, so consecutive ticks neither miss nor
    # double-report it (#2203).
    test "window boundaries: exactly 20 minutes old is in, exactly 15 is the next tick's" do
      on_start = txn("txn_start", [payment("action_required", "2026-10-23T11:40:00Z")])
      on_end = txn("txn_end", [payment("action_required", "2026-10-23T11:45:00Z")])

      Engram.Paddle.ClientMock
      |> expect(:list_ready_transactions, 3, fn _since -> {:ok, [on_start, on_end]} end)

      ExUnit.CaptureLog.capture_log(fn ->
        # Tick 12:00 reports the 20-minute-old attempt only.
        assert Reconciliation.report_stalled_checkouts(@anchor) == 1
        # Tick 12:05 reports the one that was exactly 15 minutes old at 12:00.
        assert Reconciliation.report_stalled_checkouts(DateTime.add(@anchor, 300, :second)) == 1
        # Tick 11:55 reports neither: its window ends at 11:40, exclusive.
        assert Reconciliation.report_stalled_checkouts(DateTime.add(@anchor, -300, :second)) == 0
      end)
    end

    # The windows only tile if each tick owns exactly one cron interval: a
    # wider window double-reports, a narrower one skips attempts (#2203).
    test "runs every 5 minutes and the window width equals the cron interval" do
      # PaddleReconcile has two entries: the daily drift run (one minute) and
      # the scan (many).
      [minutes] =
        for {expr, PaddleReconcile} <- Engram.Test.ObanWorkers.crontab(),
            minutes = Enum.sort(Oban.Cron.Expression.parse!(expr).minutes),
            length(minutes) > 1,
            do: minutes

      gaps = Enum.zip_with(minutes, tl(minutes) ++ [hd(minutes) + 60], &(&2 - &1))
      window_min = div(Reconciliation.stalled_scan_window_seconds(), 60)

      assert window_min == 5
      assert gaps == List.duplicate(window_min, div(60, window_min))

      # Every cron tick is an anchor, and a job inserted up to just under half
      # a window late (busy leader, DB pool wait) or early still anchors on its
      # own tick, so a delayed insert neither skips nor repeats a window.
      half = div(Reconciliation.stalled_scan_window_seconds(), 2)

      for m <- minutes do
        tick = DateTime.new!(~D[2026-10-23], Time.new!(12, m, 0))
        assert PaddleReconcile.scan_anchor(tick) == tick
        assert PaddleReconcile.scan_anchor(DateTime.add(tick, half - 1, :second)) == tick
        assert PaddleReconcile.scan_anchor(DateTime.add(tick, -half, :second)) == tick
      end
    end

    # At 15-min cadence a 15-min timeout could not stack scans; at 5 min a hung
    # Paddle call could pile three into the 2-slot maintenance queue.
    test "a scan times out before the next tick; the daily run keeps its long timeout" do
      scan = %Oban.Job{args: %{"scan" => "stalled_checkouts"}}

      assert PaddleReconcile.timeout(scan) < Reconciliation.stalled_scan_window_seconds() * 1000
      assert PaddleReconcile.timeout(%Oban.Job{args: %{}}) == :timer.minutes(15)
    end

    test "a Paddle fetch failure errors the job so Oban retries the same window" do
      Engram.Paddle.ClientMock
      |> expect(:list_ready_transactions, fn _ -> {:error, {:paddle_error, 500, %{}}} end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :fetch_failed} =
                 perform_job(PaddleReconcile, %{"scan" => "stalled_checkouts"})
      end)
    end

    # The grace: a window anchored on the tick ends 15 minutes before the run,
    # so a payment younger than that can never be reported.
    test "anchors on the cron tick, even when inserted late, so windows tile and keep the grace" do
      assert PaddleReconcile.scan_anchor(~U[2026-10-23 12:14:00.020Z]) == ~U[2026-10-23 12:14:00Z]
      # DB clock a hair early: still that tick, not the previous minute.
      assert PaddleReconcile.scan_anchor(~U[2026-10-23 12:13:59.990Z]) == ~U[2026-10-23 12:14:00Z]
      assert PaddleReconcile.scan_anchor(~U[2026-10-23 12:19:00.400Z]) == ~U[2026-10-23 12:19:00Z]
      # Inserted 2m20s late: still the 12:14 tick, not 12:16 (the old
      # nearest-minute rounding shifted the window by the delay).
      assert PaddleReconcile.scan_anchor(~U[2026-10-23 12:16:20Z]) == ~U[2026-10-23 12:14:00Z]
    end

    test "is a no-op on self-host" do
      Application.put_env(:engram, :billing_enabled, false)
      assert Reconciliation.report_stalled_checkouts(@anchor) == 0
    end

    # Same worker, different job: uniqueness on [:worker] alone would silently
    # drop one when both are enqueued within the unique period.
    test "the daily drift run and the scan are not deduped against each other" do
      {:ok, _} = Oban.insert(PaddleReconcile.new(%{}))
      {:ok, scan} = Oban.insert(PaddleReconcile.new(%{"scan" => "stalled_checkouts"}))
      refute scan.conflict?
      assert_enqueued(worker: PaddleReconcile, args: %{"scan" => "stalled_checkouts"})
    end
  end
end
