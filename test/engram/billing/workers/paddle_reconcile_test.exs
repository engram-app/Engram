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
           "items" => [%{"price" => %{"id" => "pri_starter_test"}}],
           "current_billing_period" => %{"ends_at" => "2026-06-30T00:00:00Z"}
         }
       ]}
    end)

    assert :ok = perform_job(PaddleReconcile, %{})
  end
end
