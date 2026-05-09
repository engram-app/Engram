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
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
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
        tags: [:user_id],
        description:
          "T3.7 per-user DEK rotation snoozed because lock held by another rotation"
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
      )
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {EngramWeb, :count_users, []}
    ]
  end
end
