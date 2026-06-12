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

  Metrics:

    * `engram_prom_ex_crypto_dek_cache_total` — tags `[:outcome]`.
    * `engram_prom_ex_crypto_decrypt_batch_duration_microseconds` —
      tags `[:kind]`.
    * `engram_prom_ex_crypto_decrypt_batch_rows` — tags `[:kind]`.

  These events are also declared in `EngramWeb.Telemetry.metrics/0`,
  but that list feeds LiveDashboard only — this plugin is what gets
  them onto the scraped `/metrics` endpoint.

  Cardinality contract: only the atoms above. NEVER add user_id,
  vault_id, or note ids.
  """

  use PromEx.Plugin

  @dek_cache_event [:engram, :crypto, :dek_cache]
  @decrypt_batch_event [:engram, :crypto, :decrypt_batch]

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
        )
      ]
    )
  end
end
