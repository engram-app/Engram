defmodule EngramWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},

      # Dedicated poller for WebSocket gauges. Runs at a slower 30s cadence
      # — every call is O(n) over Process.list/0 and the distribution
      # collector emits one event per channel pid, so a 10s cadence on a
      # many-socket app would be needlessly noisy. See
      # `Engram.Telemetry.WebSocketPoller` for the gauge definitions and
      # `metrics/0` below for their Prometheus mapping.
      Supervisor.child_spec(
        {:telemetry_poller,
         measurements: websocket_measurements(),
         period: websocket_poll_period(),
         name: :engram_websocket_poller},
        id: :engram_websocket_poller
      )
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("engram.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("engram.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("engram.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("engram.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("engram.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Crypto / Encryption Metrics — T3-audit H2.
      #
      # Every Tier-3 encryption phase emitted telemetry for operationally-
      # critical signals. Until they are registered here as Telemetry.Metrics
      # counters, no PromEx/Sentry pipeline can see them. Pinned by
      # `test/engram_web/telemetry_test.exs` so future drift breaks the build.
      counter("engram.crypto.rotate.user.count",
        tags: [:status, :reason_label],
        description: "MasterRotation per-user outcome (T3.5 master-key cutover)"
      ),
      summary("engram.crypto.rotate.user.duration_us",
        unit: {:native, :microsecond},
        tags: [:status],
        description: "MasterRotation per-user duration"
      ),
      counter("engram.crypto.aad_rebind.user.count",
        tags: [:status, :reason_label],
        description: "AadRebind per-user outcome (T3.6 backfill)"
      ),
      summary("engram.crypto.aad_rebind.user.duration_us",
        unit: {:native, :microsecond},
        tags: [:status],
        description: "AadRebind per-user duration"
      ),
      counter("engram.crypto.migrate_provider.user.count",
        tags: [:target_provider, :status, :reason_label],
        description: "Phase 3 per-user provider migration outcome (Local↔AwsKms)"
      ),
      summary("engram.crypto.migrate_provider.user.duration_us",
        unit: {:native, :microsecond},
        tags: [:target_provider, :status],
        description: "Phase 3 per-user provider migration duration"
      ),
      counter("engram.crypto.rotate.dek.count",
        tags: [:status, :reason_label],
        description: "UserDekRotation per-DEK outcome (T3.7 per-user DEK rotation)"
      ),
      summary("engram.crypto.rotate.dek.duration_us",
        unit: {:native, :microsecond},
        tags: [:status],
        description: "UserDekRotation per-DEK duration"
      ),
      counter("engram.crypto.rotate.dek.row_failed.count",
        event_name: [:engram, :crypto, :rotate, :dek, :row_failed],
        measurement: :count,
        tags: [:table, :phase, :status],
        description:
          "T3.7 per-row failure during user DEK rotation (decrypt-both-failed, missing-id, etc.)"
      ),
      counter("engram.crypto.rotate.dek.snoozed.count",
        event_name: [:engram, :crypto, :rotate, :dek, :snoozed],
        measurement: :count,
        # No :user_id tag — one Prometheus series per user is unbounded
        # cardinality (#517). user_id stays in event metadata for logs.
        description: "T3.7 per-user DEK rotation snoozed because lock held by another rotation"
      ),
      counter("engram.crypto.aad_rebind.attachment_skipped.count",
        description:
          "Attachments NOT rebound by AadRebind (intentional — converge on next upload). Non-zero count means the user has unconverged S3 blobs that still read as legacy AAD."
      ),
      counter("engram.crypto.previous_fallback_hit.count",
        tags: [:status],
        description:
          "Previous-master fallback hits — should drop to 0 post-rotation; non-zero `:failed` status is catastrophic"
      ),
      counter("engram.crypto.boot_canary.count",
        tags: [:status, :reason_label],
        description: "Boot canary outcomes — `:failed` halts boot via BootCanaryGuard"
      ),
      # Read-path crypto cost (perf wave 2026-06-12). dek_cache hit/miss is
      # the leading indicator of unwrap cost (a miss pairs with a provider
      # unwrap — network RPC under AwsKms); decrypt_batch sizes the
      # per-request decrypt fan-out on list endpoints + sync manifest.
      counter("engram.crypto.dek_cache.count",
        tags: [:outcome],
        description: "DekCache lookups by outcome (:hit | :miss)"
      ),
      summary("engram.crypto.decrypt_batch.duration_us",
        tags: [:kind],
        description:
          "Batch decrypt wall-time in µs per kind (:notes | :manifest_notes | :manifest_attachments)"
      ),
      summary("engram.crypto.decrypt_batch.count",
        measurement: :count,
        tags: [:kind],
        description: "Rows decrypted per batch, per kind"
      ),
      counter("engram.search.decrypt_failed.count",
        description:
          "Search candidate decrypt failures — non-zero rate is an alarm signal (key drift, tampering)"
      ),
      counter("engram.search.payload_shape_mismatch.count",
        description: "Qdrant payload shape mismatches — drift between writer and reader"
      ),
      counter("engram.indexing.encrypt_failed.count",
        description: "Indexing-time encrypt failures (e.g. missing DEK at re-embed)"
      ),

      # T3.7 — rotation gate blocked events (channel + worker bypass paths).
      # Emitted whenever a SyncChannel handler or Oban worker is turned away
      # because the user's DEK rotation is in flight. Operators can use the
      # rate to size the retry window and quantify contention per rotation run.
      counter("engram.crypto.rotate.dek.gate_blocked.count",
        event_name: [:engram, :crypto, :rotate, :dek, :gate_blocked],
        measurement: :count,
        tags: [:gate_path, :op],
        description:
          "T3.7 writes/reads blocked by RotationGate (channel/worker bypass path). Tags: gate_path (:channel | :worker), op (handler/worker name)"
      ),

      # PR #289 — embed rate-limit defense surfaces.
      #
      # Three events emitted by the Voyage rate-limit defense-in-depth layers.
      # Declared here so a future reporter (PromEx / telemetry_metrics_prometheus
      # / StatsD / OTel) picks them up without a second PR. Pinned by
      # `test/engram_web/telemetry_test.exs`.
      counter("engram.embed.rate_limited.count",
        # No :vault_id tag — one Prometheus series per vault is unbounded
        # cardinality (#517). vault_id stays in event metadata for logs.
        description:
          "Real Voyage 429 (post-network) — each event = one snoozed EmbedNote job. Layer 1 surface. Non-zero = either real Voyage rate-limit hits OR Layer 2 leaking; use `engram.embed.client_rate_limited.count` to distinguish."
      ),
      counter("engram.embed.client_rate_limited.count",
        tags: [:purpose],
        description:
          "Synthetic 429 from local Hammer throttle (Layer 2). Tag `:purpose` (:query | :index) is the signal for rebalancing VOYAGE_RPM vs VOYAGE_QUERY_RPM from facts."
      ),
      counter("engram.oban.discarded.count",
        tags: [:worker, :queue],
        description:
          "Jobs that exhausted max_attempts and were dropped by Oban. Layer 3 surface — non-zero is a triage signal."
      ),

      # #687 — rate-limiter visibility (Redis-backed metrics dropped with #684).
      # Mirrored on the scraped /metrics endpoint by Engram.PromEx.RateLimiter.
      counter("engram.rate_limiter.hit.count",
        tags: [:purpose, :result],
        description:
          "Rate-limiter allow/deny by bounded `:purpose` (:preauth | :http | :api_rps | :voyage_embed | :other). Never tags the bucket key (embeds user_id/ip/path)."
      ),
      counter("engram.rate_limiter.remote_inc.count",
        tags: [:result],
        description:
          "DistributedETS cross-node PubSub increments, `:result` :applied | :dropped. The warm-window signal: `:applied` ramping from a new node's boot = warming from peers; `:dropped` > 0 = lost increments."
      ),

      # PR #244 — Paddle webhook reliability surfaces.
      #
      # Emitted via :telemetry.span/3 in EngramWeb.WebhookController.paddle/2.
      # Declared here so a future reporter (PromEx) picks them up automatically.
      counter("engram.paddle.webhook.start.count",
        event_name: [:engram, :paddle, :webhook, :start],
        measurement: :system_time,
        tags: [:event_type],
        description:
          "One per Paddle webhook entry. Tag `:event_type` is the Paddle event name (e.g. `subscription.created`)."
      ),
      summary("engram.paddle.webhook.stop.duration",
        event_name: [:engram, :paddle, :webhook, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:event_type, :result],
        description:
          "Webhook handler latency. Tag `:result` (:ok | :error) distinguishes successful upsert from swallowed `{:error, _}` (silent-200 path)."
      ),
      counter("engram.paddle.webhook.exception.count",
        event_name: [:engram, :paddle, :webhook, :exception],
        measurement: :duration,
        tags: [:event_type, :kind],
        description:
          "Webhook handler raised. Non-zero = Paddle will retry; investigate via Sentry trace + reconciliation drift."
      ),
      counter("engram.paddle.reconcile.run.count",
        event_name: [:engram, :paddle, :reconcile, :run],
        measurement: :paddle_total,
        tags: [:outcome],
        description:
          "Daily reconciliation runs by outcome. `outcome` is :ok | :billing_disabled | :fetch_failed | :max_pages_exceeded | :pagination_loop. Non-:ok counts = silent-truncation rate; page if sustained."
      ),

      # WebSocket gauges — emitted by Engram.Telemetry.WebSocketPoller every
      # 30s. Captures the two failure modes the observability-coverage
      # milestone calls out: silent socket-count growth and per-socket
      # process bloat ("users holding open huge subscriptions").
      #
      # `topic_prefix` is bounded — one of "sync" / "user" / "presence" /
      # "total" (plus "unknown" for label drift). No per-user / per-vault
      # tags ever escape; that's enforced by web_socket_poller_test.exs.
      last_value("engram.websocket.count",
        event_name: [:engram, :websocket, :count],
        measurement: :count,
        tags: [:topic_prefix],
        description:
          "Live count of Phoenix Channel processes, split by topic prefix (sync/user/presence/total). Polled every 30s."
      ),
      distribution("engram.websocket.socket_bytes",
        event_name: [:engram, :websocket, :socket_bytes],
        measurement: :bytes,
        tags: [:topic_prefix],
        unit: :byte,
        reporter_options: [
          # Log-scaled buckets from 1 KiB to ~100 MiB. Covers the "idle
          # 30 KB channel" case through the "user pinned a 50 MB
          # subscription buffer" case the scope flags as the failure mode.
          buckets: [
            1_024,
            4_096,
            16_384,
            65_536,
            262_144,
            1_048_576,
            4_194_304,
            16_777_216,
            67_108_864,
            268_435_456
          ]
        ],
        description:
          "Per-process RAM footprint of each Phoenix Channel server. Bucket spike = a tenant pinning a fat subscription."
      )
    ]
  end

  # Poll cadence: 30s. Faster gets noisy on a many-socket app
  # (each poll is O(n) over Process.list/0 and emits one event per
  # channel pid for the distribution histogram); slower misses spikes.
  @websocket_poll_period :timer.seconds(30)

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {EngramWeb, :count_users, []}
    ]
  end

  defp websocket_measurements do
    [
      {Engram.Telemetry.WebSocketPoller, :measure, []}
    ]
  end

  @doc false
  def websocket_poll_period, do: @websocket_poll_period
end
