defmodule Engram.PromEx.Crypto do
  @moduledoc """
  PromEx plugin for read-path crypto cost (PR #530 telemetry).

  Subscribes to:

    * `[:engram, :crypto, :dek_cache]` — `%{count: 1}`, metadata
      `%{outcome: :hit | :miss}`. A miss pairs with a provider unwrap
      (network RPC under AwsKms), so the hit/miss ratio is the leading
      indicator of unwrap cost on the read path.
    * `[:engram, :crypto, :decrypt_batch]` — `%{count: rows,
      duration_us: µs}`, metadata `%{kind: :notes | :manifest_notes |
      :manifest_attachments}`. Sizes the per-request decrypt fan-out on
      list endpoints + the sync manifest.

    * `[:engram, :envelope, :compression_gate]`: `%{allowed: 0 | 1}`,
      emitted by `Engram.Crypto.CompressionGate` on every verdict change.
    * `[:engram, :envelope, :compression_gate, :reason]`: `%{current: 0 | 1}`,
      metadata `%{reason: atom()}`, one-hot over the gate's five reasons on
      every reason change.

  Metrics:

    * `engram_prom_ex_crypto_dek_cache_total` — tags `[:outcome]`.
    * `engram_prom_ex_crypto_decrypt_batch_duration_microseconds` —
      tags `[:kind]`.
    * `engram_prom_ex_crypto_decrypt_batch_rows` — tags `[:kind]`.
    * `engram_prom_ex_crypto_compression_gate_allowed`: 1 while this node
      may write compressed envelopes, 0 while the cluster gate blocks it.
      Untagged: the last value is the verdict. 0 on every node for over an
      hour means compression is off fleet-wide (alert on it).
    * `engram_prom_ex_crypto_compression_gate_reason`: tags `[:reason]`
      (five atoms); the series at 1 is the current reason.

  These events are also declared in `EngramWeb.Telemetry.metrics/0`,
  but that list feeds LiveDashboard only — this plugin is what gets
  them onto the scraped `/metrics` endpoint.

  Cardinality contract: only the atoms above. NEVER add user_id,
  vault_id, or note ids.
  """

  use PromEx.Plugin

  @dek_cache_event [:engram, :crypto, :dek_cache]
  @decrypt_batch_event [:engram, :crypto, :decrypt_batch]
  @gate_event [:engram, :envelope, :compression_gate]
  @gate_reason_event [:engram, :envelope, :compression_gate, :reason]

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :crypto)

    Event.build(
      :engram_crypto_event_metrics,
      [
        counter(
          metric_prefix ++ [:dek_cache, :total],
          event_name: @dek_cache_event,
          description: "DekCache lookups by outcome (hit | miss).",
          tags: [:outcome]
        ),
        distribution(
          metric_prefix ++ [:decrypt_batch, :duration, :microseconds],
          event_name: @decrypt_batch_event,
          measurement: :duration_us,
          description: "Batch decrypt wall-time per kind.",
          reporter_options: [
            buckets: [100, 500, 1_000, 5_000, 10_000, 50_000, 100_000, 500_000, 1_000_000]
          ],
          tags: [:kind]
        ),
        distribution(
          metric_prefix ++ [:decrypt_batch, :rows],
          event_name: @decrypt_batch_event,
          measurement: :count,
          description: "Rows decrypted per batch, per kind.",
          reporter_options: [
            buckets: [1, 10, 50, 100, 500, 1_000, 5_000, 10_000]
          ],
          tags: [:kind]
        ),
        last_value(
          metric_prefix ++ [:compression_gate, :allowed],
          event_name: @gate_event,
          measurement: :allowed,
          description: "1 while envelope compression is allowed cluster-wide, 0 while blocked."
        ),
        last_value(
          metric_prefix ++ [:compression_gate, :reason],
          event_name: @gate_reason_event,
          measurement: :current,
          description: "Compression gate reason, one-hot: 1 on the current reason.",
          tags: [:reason]
        )
      ]
    )
  end
end
