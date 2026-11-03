defmodule Engram.Maintenance.PruneTest do
  # Retention for two tables that had none bounded (Job Load Audit 2026-11-03):
  # client_origin_stats (no retention at all) and processed_webhook_events
  # (one unbounded DELETE per run). Red before: `OriginStats.prune/2` did not
  # exist and the webhook prune took no cap.
  use Engram.DataCase, async: false

  alias Engram.Abuse.OriginStats
  alias Engram.Repo
  alias Engram.Webhooks.Idempotency

  test "origin stats older than 30 days go, in capped batches; newer stay" do
    user = insert(:user)
    uid = Ecto.UUID.dump!(user.id)
    today = Date.utc_today()

    for {d, c} <- [{-40, "a"}, {-35, "b"}, {-31, "c"}, {-29, "d"}, {0, "e"}] do
      Repo.query!(
        "INSERT INTO client_origin_stats (user_id, day, fingerprint_class, request_count, created_at, updated_at) VALUES ($1, $2, $3, 1, now(), now())",
        [uid, Date.add(today, d), c]
      )
    end

    assert OriginStats.prune(1, 2) == 2
    assert OriginStats.prune() == 1

    %{rows: rows} = Repo.query!("SELECT fingerprint_class FROM client_origin_stats ORDER BY 1")
    assert rows == [["d"], ["e"]]
  end

  test "webhook events past 7 days go in capped batches; Paddle adjustment claims stay" do
    for {p, id, days} <- [
          {"paddle", "a", 10},
          {"paddle", "b", 9},
          {"paddle", "c", 1},
          {"paddle_adjustment", "d", 30}
        ] do
      Repo.query!(
        "INSERT INTO processed_webhook_events (provider, event_id, inserted_at) VALUES ($1, $2, now() - make_interval(days => $3))",
        [p, id, days]
      )
    end

    assert Idempotency.prune(1, 1) == {:ok, 1}
    assert Idempotency.prune() == {:ok, 1}

    %{rows: rows} = Repo.query!("SELECT event_id FROM processed_webhook_events ORDER BY 1")
    assert rows == [["c"], ["d"]]
  end
end
