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

**Categories:** the source of truth is the `@categories` list in `Engram.Logger.Category` (read it, don't count from here). As of 2026-11-11 it is: `http`, `sync`, `search`, `auth`, `billing`, `crypto`, `lifecycle`, `oban`, `oban_retry`, `boot`, `data`, `websocket`, `client`.

- `info` ships to Loki only for the categories in `@info_to_loki`: `billing`, `crypto`, `lifecycle`, `oban`, `boot`, `websocket`. Every other category ships only `warning`/`error` (by level).
- Caveat: `websocket` is in `@info_to_loki` but absent from the Fluent Bit `rewrite_tag` regex that actually routes to Loki (engram-infra `main/envs/prod/fluent-bit/firelens.conf`, `^(billing|crypto|lifecycle|oban|boot)$`), so `info` + `websocket` does not reach Loki today (see the NOTE in `category.ex`).
- `oban_retry` is a failed Oban attempt that will be retried. It is its own category so the Loki `oban-discard` rule (exact match on category `oban`) never reads a retry as a discard (PR #2578). Warning-only, so it ships by level.

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


Design spec: the logging taxonomy redesign (2026-06-23) in the team's Engram vault. Ask a maintainer for vault access.
