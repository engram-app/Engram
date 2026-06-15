import Config

# TLS is terminated at the edge (AWS ALB / nginx) — no force_ssl in app.
# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
