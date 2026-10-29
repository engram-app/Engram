# Context Doc: Logging Conventions

_Moved from AGENTS.md on 2026-10-28._

Redaction internals and the filter failure modes: `docs/context/log-redaction-boundaries.md`.


**Principle:** every log line must earn its place by serving *alerting* or *diagnosis*. Healthy systems are quiet — logs are for the exceptional. Routine success (e.g. a per-request 2xx) is not logged to Loki.

**Levels:**

| Level | Means |
|-------|-------|
| `debug` | Developer firehose. Never shipped to Loki. |
| `info` | Normal noteworthy events. |
| `warning` | Off but not broken. |
| `error` | Broken, needs attention. |

**Categories** — nine, the source of truth is `Engram.Logger.Category`: `http`, `sync`, `search`, `auth`, `billing`, `crypto`, `lifecycle`, `oban`, `boot`. Only `billing`, `crypto`, `lifecycle`, `oban`, `boot` ship `info` to Loki; the rest ship only `warning`/`error` (by level).

**How to log (the rule):** always build metadata via `Engram.Logger.Metadata.with_category(level, category, kw)` — it stamps `:category` and the computed `:loki_ship`.

```elixir
Logger.info("subscription created",
  Engram.Logger.Metadata.with_category(:info, :billing,
    paddle_subscription_id: id))
```

NEVER interpolate sensitive values into the message string. `RedactFilter` scrubs sensitive *metadata* keys only — never message strings — so sensitive values must travel as metadata keys (and new metadata keys must be added to the allowlist in `config/config.exs`).

**Sink model:** CloudWatch = full-fidelity archive (Fluent Bit `Match *`, everything). Grafana Loki = curated signal: only lines where `loki_ship` is true (all `warning`/`error`, plus allowlisted `info`). Query Loki day-to-day; CloudWatch is the on-demand backstop.

**Querying Loki:** prod logs are structured JSON (`logger_json` Basic, `metadata: :all`); dev/test stay text. `logger_json` nests metadata under a `metadata` object, so in LogQL after `| json` the fields are `metadata_category`, `metadata_loki_ship`, `metadata_request_id`, etc.

**Depth on demand:** operators can temporarily raise a single module to `:debug` at runtime via release rpc — `Engram.Logger.DebugToggle.enable(SomeModule)` to flip it on while chasing a live issue, `reset(SomeModule)` to flip it back (levels also reset on node restart).


Design spec: Engram vault, `50 Engineering/_Superpowers Specs/` (logging taxonomy redesign, 2026-06-23).
