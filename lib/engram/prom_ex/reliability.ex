defmodule Engram.PromEx.Reliability do
  @moduledoc """
  PromEx plugin for cross-cutting incident counters — the signals an on-call
  alert should key on. Subscribes to in-house telemetry the bundled plugins
  don't cover and puts it on the scraped `/metrics` endpoint (the same events
  also feed LiveDashboard via `EngramWeb.Telemetry`, but that is not scraped).

  Events + metrics:

    * `[:engram, :auth, :rejected]` → `..._auth_rejected_total`, tags
      `[:reason, :source]` — every auth failure across the HTTP plug and the
      WebSocket connect path. Alert on rate spikes; `reason` names the variant
      (`claim_invalid:exp`, `invalid_azp`, `could_not_reach_jwks_url`).
    * `[:engram, :repo, :tenant_guard_violation]` → `..._tenant_guard_violation_total`,
      tags `[:table]` — a tenant-scoped query run with no scope. Any non-zero
      value is a bug; this is the multi-tenant isolation tripwire.
    * `[:engram, :repo, :tenant_check_skipped]` → `..._tenant_check_skipped_total`,
      tags `[:table]` — honored `skip_tenant_check` bypasses; a baseline to
      alert on rate changes (an accidental skip on a request path).
    * `[:engram, :embed, :failed]` → `..._embed_failed_total`, tags
      `[:error_kind, :status]` — per-attempt embed failures, visible before the
      terminal Oban discard.
    * `[:engram, :oban, :discarded]` → `..._oban_discarded_total`, tags
      `[:worker, :queue, :error_kind]` — jobs dropped after max_attempts.

  Cardinality contract: only the bounded tags above. NEVER user_id, vault_id,
  note_id, tenant_id, or job_id — those would explode the series count.
  """

  use PromEx.Plugin

  @impl true
  def event_metrics(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    metric_prefix = PromEx.metric_prefix(otp_app, :reliability)

    Event.build(
      :engram_reliability_event_metrics,
      [
        counter(
          metric_prefix ++ [:auth, :rejected, :total],
          event_name: [:engram, :auth, :rejected],
          description: "Auth rejections by reason + source (http | socket).",
          tags: [:reason, :source]
        ),
        counter(
          metric_prefix ++ [:tenant_guard_violation, :total],
          event_name: [:engram, :repo, :tenant_guard_violation],
          description: "Tenant-scoped queries run with no tenant context (isolation tripwire).",
          tags: [:table]
        ),
        counter(
          metric_prefix ++ [:tenant_check_skipped, :total],
          event_name: [:engram, :repo, :tenant_check_skipped],
          description: "Honored skip_tenant_check bypasses on a tenant table.",
          tags: [:table]
        ),
        counter(
          metric_prefix ++ [:embed, :failed, :total],
          event_name: [:engram, :embed, :failed],
          description: "Per-attempt embed failures by error class + HTTP status.",
          tags: [:error_kind, :status]
        ),
        counter(
          metric_prefix ++ [:oban, :discarded, :total],
          event_name: [:engram, :oban, :discarded],
          description: "Oban jobs discarded after max_attempts.",
          tags: [:worker, :queue, :error_kind]
        )
      ]
    )
  end
end
