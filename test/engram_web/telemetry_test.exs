defmodule EngramWeb.TelemetryTest do
  use ExUnit.Case, async: true

  describe "metrics/0 — crypto observability (T3-audit H2)" do
    setup do
      # Telemetry.Metrics stores `name` as the atom-list event path with the
      # measurement appended, e.g. [:engram, :crypto, :rotate, :user, :count].
      # We compare in dotted-string form for readability in test assertions.
      metric_names =
        EngramWeb.Telemetry.metrics()
        |> Enum.map(fn metric ->
          metric.name |> Enum.map_join(".", &Atom.to_string/1)
        end)
        |> MapSet.new()

      {:ok, names: metric_names}
    end

    # T3-audit H2 — every Tier-3 PR introduced telemetry events for
    # operationally-critical crypto signals. Until they're registered as
    # Telemetry.Metrics counters/summaries, no PromEx/Sentry pipeline can
    # see them — every "we emit telemetry" defense in T3.5/T3.6 collapses
    # into "we emit nothing reachable." This test pins each event so the
    # registration cannot quietly drift.

    test "registers engram.crypto.rotate.user counter (T3.5 master-key rotation)", %{
      names: names
    } do
      assert "engram.crypto.rotate.user.count" in names,
             "MasterRotation per-user outcome must be counted (status, reason_label)"
    end

    test "registers engram.crypto.aad_rebind.user counter (T3.6 backfill)", %{names: names} do
      assert "engram.crypto.aad_rebind.user.count" in names,
             "AadRebind per-user outcome must be counted (status, reason_label)"
    end

    test "registers engram.crypto.aad_rebind.attachment_skipped counter (T3-audit H5)", %{
      names: names
    } do
      assert "engram.crypto.aad_rebind.attachment_skipped.count" in names,
             "Per-user count of unconverged attachments — operator drain log honesty"
    end

    test "registers engram.crypto.previous_fallback_hit counter (T3.5 / M4)", %{names: names} do
      assert "engram.crypto.previous_fallback_hit.count" in names,
             "Previous-master fallback hits must be counted — should drop to 0 post-rotation"
    end

    test "registers engram.crypto.boot_canary counter (T3.5 boot guard)", %{names: names} do
      assert "engram.crypto.boot_canary.count" in names,
             "Boot canary outcomes must be counted (provisioned, ok, failed:reason_label)"
    end

    test "registers engram.search.decrypt_failed counter", %{names: names} do
      assert "engram.search.decrypt_failed.count" in names,
             "Search decrypt failures must page operators — alarm signal"
    end

    test "registers engram.search.payload_shape_mismatch counter", %{names: names} do
      assert "engram.search.payload_shape_mismatch.count" in names,
             "Payload-shape mismatches indicate Qdrant schema drift"
    end

    test "registers engram.indexing.encrypt_failed counter", %{names: names} do
      assert "engram.indexing.encrypt_failed.count" in names,
             "Indexing encrypt failures (e.g. missing DEK) must be counted"
    end

    # T3.7 — per-user DEK rotation telemetry
    test "registers engram.crypto.rotate.dek counter (T3.7 per-user DEK rotation)", %{
      names: names
    } do
      assert "engram.crypto.rotate.dek.count" in names,
             "UserDekRotation per-DEK outcome must be counted (status, reason_label)"
    end

    test "registers engram.crypto.rotate.dek duration summary (T3.7 per-user DEK rotation)", %{
      names: names
    } do
      assert "engram.crypto.rotate.dek.duration_us" in names,
             "UserDekRotation per-DEK duration must be measured"
    end

    test "registers engram.crypto.rotate.dek.row_failed counter (T3.7 per-row failures)", %{
      names: names
    } do
      assert "engram.crypto.rotate.dek.row_failed.count" in names,
             "Per-row T3.7 rotation failures (decrypt-both-failed, missing-id) must be counted"
    end

    test "registers engram.crypto.rotate.dek.snoozed counter (T3.7 lock contention)", %{
      names: names
    } do
      assert "engram.crypto.rotate.dek.snoozed.count" in names,
             "T3.7 snooze events (lock held by another rotation) must be counted"
    end

    test "registers engram.crypto.rotate.dek.gate_blocked counter (T3.7 channel/worker bypass)",
         %{names: names} do
      assert "engram.crypto.rotate.dek.gate_blocked.count" in names,
             "T3.7 writes/reads blocked at channel/worker bypass path must be counted"
    end

    # Phase 3 — per-user provider migration telemetry (Local↔AwsKms cutover).
    test "registers engram.crypto.migrate_provider.user counter (Phase 3 provider migration)", %{
      names: names
    } do
      assert "engram.crypto.migrate_provider.user.count" in names,
             "ProviderMigration per-user outcome must be counted (target_provider, status, reason_label)"
    end

    test "registers engram.crypto.migrate_provider.user duration summary (Phase 3 provider migration)",
         %{names: names} do
      assert "engram.crypto.migrate_provider.user.duration_us" in names,
             "ProviderMigration per-user duration must be measured"
    end
  end

  describe "metrics/0 — embed rate-limit observability (PR #289)" do
    # Same pinning rationale as the crypto block: PR #289 introduced three
    # telemetry events as defense-in-depth against Voyage rate-limit cascades
    # (Layer 1 snooze on real 429, Layer 2 synthetic 429 from local throttle,
    # Layer 3 Oban discard surface). Without Telemetry.Metrics declarations,
    # any future reporter (PromEx / telemetry_metrics_prometheus / StatsD)
    # silently ignores them — the "we emit telemetry" defense in PR #289
    # collapses into "we emit nothing reachable." This block keeps each
    # event declared so the registration cannot quietly drift.

    setup do
      names =
        EngramWeb.Telemetry.metrics()
        |> Enum.map(fn metric ->
          metric.name |> Enum.map_join(".", &Atom.to_string/1)
        end)
        |> MapSet.new()

      {:ok, names: names}
    end

    test "registers engram.embed.rate_limited counter (Layer 1 — real Voyage 429)", %{
      names: names
    } do
      assert "engram.embed.rate_limited.count" in names,
             "Real Voyage 429 (post-network) snoozes must be counted — primary signal that Voyage's actual rate-limit is hitting us"
    end

    test "registers engram.embed.client_rate_limited counter (Layer 2 — local throttle)", %{
      names: names
    } do
      assert "engram.embed.client_rate_limited.count" in names,
             "Synthetic 429 from local Hammer throttle must be counted — tag :purpose (:query | :index) is the signal for rebalancing VOYAGE_RPM vs VOYAGE_QUERY_RPM"
    end

    test "registers engram.oban.discarded counter (Layer 3 — terminal job drops)", %{
      names: names
    } do
      assert "engram.oban.discarded.count" in names,
             "Oban jobs that exhausted max_attempts must be counted — non-zero is a triage signal"
    end

    test "registers engram.paddle.webhook.start counter (#244)", %{names: names} do
      assert "engram.paddle.webhook.start.count" in names,
             "Each Paddle webhook entry must be counted so PromEx can attach"
    end

    test "registers engram.paddle.webhook.stop summary (#244)", %{names: names} do
      assert "engram.paddle.webhook.stop.duration" in names,
             "Webhook latency + result must be summarised so a PromEx histogram exposes the silent-200 path"
    end

    test "registers engram.paddle.webhook.exception counter (#244)", %{names: names} do
      assert "engram.paddle.webhook.exception.count" in names,
             "Webhook raises must be counted so PromEx + Sentry both see them"
    end
  end
end
