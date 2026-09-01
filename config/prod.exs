import Config

# TLS is terminated at the edge (AWS ALB / nginx) — no force_ssl in app.
# Do not print debug messages in production
config :logger, level: :info

# Structured JSON logging in PROD only (dev/test keep the human-readable text
# format from config/config.exs). The logger_json Basic formatter emits one
# JSON object per line with `message`/`severity`/`time` at the top level and
# ALL :logger metadata nested under a "metadata" object — so `category`,
# `loki_ship`, `request_id`, etc. appear as `metadata.*` fields, and Loki
# parses them via `| json`.
#
# Fluent Bit does NOT read the `loki_ship` boolean — it never did, and
# believing it does is what made both per-entry overrides silent no-ops for
# months (engram-app/engram-infra#1095). Routing is plain string compares on
# `severity`, `metadata.category` and `metadata.ship`; the last is written
# only by `Engram.Logger.Metadata.ship_to_loki/1`.
#
# `new/1` is not callable in config files, so the {module, opts} tuple form is
# used. This sets the formatter on the standard :logger :default_handler,
# overriding the text :default_formatter from config/config.exs for prod only.
#
# `:__sentry__` is EXCLUDED. Sentry.PlugContext writes the whole request
# context into Logger metadata — headers, cookies, query string, client IP.
# With `metadata: :all` that blob was serialized into every single log line,
# and behind mTLS the `x-amzn-mtls-clientcert-leaf` header is a ~2.5KB base64
# PEM. It is the same constant cert on every line: measured 2026-08-01, the
# average app log line was 3,858 bytes and roughly half of all app log volume
# (16MB of 32.8MB over 7d) was that one certificate repeated ~6,500 times.
#
# It carries no signal either — Engram.Sentry.Scrubber already drops
# `event.request` wholesale for Sentry events on the grounds that "none of it
# carries signal you can't get from structured logger metadata". Same
# reasoning, same blob; the log path just never got the same treatment. This
# also keeps request headers and client IPs out of Loki, which the scrubber
# was explicitly written to prevent for Sentry.
config :logger, :default_handler,
  formatter: {LoggerJSON.Formatters.Basic, metadata: {:all_except, [:__sentry__]}}

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
