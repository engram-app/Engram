defmodule Engram.Workers.OriginAbuseSweepTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Abuse.OriginStats
  alias Engram.Workers.OriginAbuseSweep

  setup do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:engram, :abuse, :pro_origin_exceeded]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)
    :ok
  end

  test "fires telemetry for each over-cap user" do
    over = insert(:user)
    under = insert(:user)

    plant_traffic(over.id, 11_000, 3)
    plant_traffic(under.id, 5_000, 3)

    assert :ok = perform_job(OriginAbuseSweep, %{})

    assert_received {[:engram, :abuse, :pro_origin_exceeded], _ref, %{count: 1},
                     %{user_id: uid, cap: 10_000, days: 3}}

    assert uid == over.id

    # No second event should have arrived for the under-cap user.
    refute_received {[:engram, :abuse, :pro_origin_exceeded], _, _, _}
  end

  test "no telemetry when nobody exceeds" do
    user = insert(:user)
    plant_traffic(user.id, 5_000, 3)

    assert :ok = perform_job(OriginAbuseSweep, %{})

    refute_received {[:engram, :abuse, :pro_origin_exceeded], _, _, _}
  end

  defp plant_traffic(user_id, per_day, days) do
    now = DateTime.utc_now()

    rows =
      for offset <- 0..(days - 1) do
        %{
          user_id: user_id,
          day: Date.add(Date.utc_today(), -offset),
          fingerprint_class: "unknown",
          request_count: per_day,
          created_at: now,
          updated_at: now
        }
      end

    Engram.Repo.insert_all(OriginStats.Row, rows, skip_tenant_check: true)
  end
end
