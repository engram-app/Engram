defmodule Engram.RuntimeConfig do
  @moduledoc """
  Pure decision helpers for `config/runtime.exs`.

  Boot-time config is awkward to test (it runs once, at release start, and
  mutates global app env). Keeping the *decisions* here — as pure functions
  over an injected `getenv` — lets the rules be unit-tested while `runtime.exs`
  stays a thin wiring layer. Mirrors `Engram.HostOrigins`, which `runtime.exs`
  already calls the same way.
  """

  @doc """
  Decides whether the `RATE_LIMIT_AUTH_OVERRIDE` env var should loosen the auth
  rate limit.

  The override exists only to stop CI/E2E stacks from 429-ing themselves; it
  must never weaken the limiter in production. Production task definitions
  never set `CI=true`, so gating on it makes a stray `RATE_LIMIT_AUTH_OVERRIDE`
  (e.g. copy-pasted from a CI compose file) a no-op in prod.

    * `{:ok, integer}`  — present and `CI=true`: apply it.
    * `{:ignored, raw}` — present but not in CI: do NOT apply; the caller logs.
    * `:none`           — absent or blank.

  `getenv` is a `(String.t() -> String.t() | nil)` (e.g. `&System.get_env/1`).
  """
  @spec rate_limit_auth_override((String.t() -> String.t() | nil)) ::
          {:ok, integer()} | {:ignored, String.t()} | :none
  def rate_limit_auth_override(getenv) when is_function(getenv, 1) do
    ci_gated_int_override(getenv, "RATE_LIMIT_AUTH_OVERRIDE")
  end

  @doc """
  Decides whether the `PRE_AUTH_RATE_LIMIT_OVERRIDE` env var should loosen the
  pre-auth (vault-pipeline) rate limit — the 401-loop defense in front of
  `/api/notes`, `/api/search`, etc. (`EngramWeb.Plugs.PreAuthRateLimit`).

  Same contract and CI-gating as `rate_limit_auth_override/1`: the override only
  exists so bulk/rapid E2E stacks don't 429 themselves (e.g. `test_77` bulk-sync
  pushing ~1000 notes through the default 600 req/60s bucket). Gated on `CI=true`
  so a stray `PRE_AUTH_RATE_LIMIT_OVERRIDE` in a prod task def can never weaken
  the defense — production never sets `CI=true`.

    * `{:ok, integer}`  — present and `CI=true`: apply it.
    * `{:ignored, raw}` — present but not in CI: do NOT apply; the caller logs.
    * `:none`           — absent or blank.
  """
  @spec pre_auth_rate_limit_override((String.t() -> String.t() | nil)) ::
          {:ok, integer()} | {:ignored, String.t()} | :none
  def pre_auth_rate_limit_override(getenv) when is_function(getenv, 1) do
    ci_gated_int_override(getenv, "PRE_AUTH_RATE_LIMIT_OVERRIDE")
  end

  # Shared rule: an integer override env var is honored only when `CI=true`,
  # so a stray copy into a prod task def is inert. Returns {:ok, int} in CI,
  # {:ignored, raw} when present outside CI, or :none when absent/blank.
  defp ci_gated_int_override(getenv, var) do
    case getenv.(var) do
      nil -> :none
      "" -> :none
      raw -> if getenv.("CI") == "true", do: {:ok, String.to_integer(raw)}, else: {:ignored, raw}
    end
  end

  @doc """
  Guards against a saas deploy booting with permissive CORS / WebSocket origin
  checks.

  CORS + `check_origin` are only locked down when `PHX_HOST` is set; without it
  both fall back to allow-all. That permissive default is fine for self-host
  (single-tenant, same-origin), but a saas deploy (`AUTH_PROVIDER=clerk`) MUST
  have `PHX_HOST` — otherwise the multi-tenant API answers `Access-Control-
  Allow-Origin: *` and the socket accepts any Origin. Fail closed (refuse to
  boot) instead of silently open.

  `ci?` is `true` in CI/E2E stacks: the `e2e-clerk` stack legitimately runs
  Clerk auth on localhost without `PHX_HOST` (and needs the permissive WS
  default so the Obsidian `app://` origin isn't rejected), so the guard is
  skipped there. Production never sets `CI=true`, so prod protection is intact.

  Returns `:ok`, or raises when `auth_provider` is `:clerk`, `phx_hosts` is
  falsy, and `ci?` is `false`.
  """
  @spec validate_saas_origins!(atom(), term(), boolean()) :: :ok
  def validate_saas_origins!(_auth_provider, _phx_hosts, true = _ci?), do: :ok

  def validate_saas_origins!(:clerk, phx_hosts, _ci?) when phx_hosts in [nil, false] do
    raise "PHX_HOST is required when AUTH_PROVIDER=clerk (saas): without it, CORS " <>
            "and WebSocket origin checks fall back to permissive allow-all defaults."
  end

  def validate_saas_origins!(_auth_provider, _phx_hosts, _ci?), do: :ok

  @doc """
  Builds the `Engram.Repo` SSL options from env.

    * `DATABASE_SSL` not in `~w(true 1)` → `[]` (no TLS; self-host/local pg).
    * SSL on, `DATABASE_SSL_MODE` unset/other → `[ssl: [verify: :verify_none]]`
      — the long-standing behavior, kept as the default so merging this can't
      break a running deploy.
    * SSL on, `DATABASE_SSL_MODE` in `verify-full`/`verify-peer` →
      `verify: :verify_peer` against the OS trust store
      (`:public_key.cacerts_get/0`; the runtime image ships `ca-certificates`,
      which includes the Amazon Root CA that AWS RDS certs chain to), with SNI
      and HTTPS-style hostname verification. This closes the MITM gap from
      `verify_none`, but is **opt-in** — the operator flips
      `DATABASE_SSL_MODE=verify-full` after confirming the chain validates on
      staging, since a CA/SNI mismatch would otherwise block DB connections.

  `db_host` is the Postgres host (from `DATABASE_URL`), used for SNI +
  hostname-check.
  """
  @spec database_ssl((String.t() -> String.t() | nil), String.t() | nil) :: keyword()
  def database_ssl(getenv, db_host) when is_function(getenv, 1) do
    if getenv.("DATABASE_SSL") in ["true", "1"] do
      [ssl: ssl_opts(getenv.("DATABASE_SSL_MODE"), db_host)]
    else
      []
    end
  end

  defp ssl_opts(mode, db_host) when mode in ["verify-full", "verify-peer"] do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: to_charlist(db_host || ""),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      depth: 4
    ]
  end

  defp ssl_opts(_mode, _db_host), do: [verify: :verify_none]
end
