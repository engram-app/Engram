import Config

# TLS is terminated at the edge (AWS ALB / nginx) — no force_ssl in app.
# Do not print debug messages in production
config :logger, level: :info

# Structured JSON logging in PROD only (dev/test keep the human-readable text
# format from config/config.exs). The logger_json Basic formatter emits one
# JSON object per line with `message`/`severity`/`time` at the top level and
# ALL :logger metadata nested under a "metadata" object — so `category`,
# `loki_ship`, `request_id`, etc. appear as `metadata.*` fields. Fluent Bit
# reads the `loki_ship` boolean and Loki parses fields via `| json`.
#
# `new/1` is not callable in config files, so the {module, opts} tuple form is
# used. This sets the formatter on the standard :logger :default_handler,
# overriding the text :default_formatter from config/config.exs for prod only.
config :logger, :default_handler, formatter: {LoggerJSON.Formatters.Basic, metadata: :all}

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
