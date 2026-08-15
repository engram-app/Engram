defmodule Engram.RuntimeConfig do
  @moduledoc """
  Pure decision helpers for `config/runtime.exs`.

  Boot-time config is awkward to test (it runs once, at release start, and
  mutates global app env). Keeping the *decisions* here — as pure functions
  over an injected `getenv` — lets the rules be unit-tested while `runtime.exs`
  stays a thin wiring layer. Mirrors `Engram.HostOrigins`, which `runtime.exs`
  already calls the same way.
  """

  # Every rate limiter that CI/E2E stacks are allowed to loosen, as
  # `{env var, application env key}`. runtime.exs walks this list, so adding a
  # limiter override is a one-line change here rather than another copy of the
  # case/log/apply block.
  #
  #   * RATE_LIMIT_AUTH_OVERRIDE      — auth limiter (EngramWeb.Plugs.RateLimit)
  #   * PRE_AUTH_RATE_LIMIT_OVERRIDE  — 401-loop defense in front of /api/notes,
  #     /api/search etc. (EngramWeb.Plugs.PreAuthRateLimit). test_77 bulk-sync
  #     pushes ~1000 notes through the default 600 req/60s bucket.
  #   * CRDT_MSG_RATE_LIMIT_OVERRIDE  — CrdtChannel per-message budget
  #   * CRDT_HS_RATE_LIMIT_OVERRIDE   — CrdtChannel handshake (STEP1/STEP2) budget
  #
  # The e2e harness's compressed workload (rapid edits, resumed-device rejoins)
  # legitimately exceeds budgets a real single user wouldn't, and the release
  # build has no other runtime lever.
  @rate_limit_overrides [
    {"RATE_LIMIT_AUTH_OVERRIDE", :rate_limit_auth_override},
    {"PRE_AUTH_RATE_LIMIT_OVERRIDE", :pre_auth_rate_limit_override},
    {"CRDT_MSG_RATE_LIMIT_OVERRIDE", :crdt_msg_rate_limit_override},
    {"CRDT_HS_RATE_LIMIT_OVERRIDE", :crdt_hs_rate_limit_override}
  ]

  @doc """
  The `{env var, application env key}` pairs for every CI-gated rate-limit
  override. See `ci_gated_int_override/2` for the gating rule.
  """
  @spec rate_limit_overrides() :: [{String.t(), atom()}]
  def rate_limit_overrides, do: @rate_limit_overrides

  # CI/E2E-only levers for the CRDT room drain (#1152), under the SAME CI=true
  # gate as the rate-limit overrides above.
  #
  # The drain is OFF in production — no room passes `idle_exit_ms`, so nothing
  # ever drains. That makes it untestable against a REAL client, and every test
  # in the suite uses a test process or a channel as the observer. These knobs
  # let a CI stack turn it on so the e2e suite proves a real Obsidian client
  # survives rooms being released out from under it mid-session: re-spin, no
  # lost edits, rename/delete still propagating.
  #
  # Nested config keys (module + key) rather than the flat app-env keys the
  # rate-limit overrides use, since both settings live under their module.
  @drain_overrides [
    {"CRDT_IDLE_EXIT_MS", {Engram.Notes.CrdtCheckpointTimer, :idle_exit_ms}},
    {"CRDT_MAX_RESIDENT_ROOMS", {Engram.Notes.CrdtRoomLru, :max_resident}}
  ]

  @doc """
  The `{env var, {module, key}}` pairs for the CI-gated CRDT room-drain levers.
  See the attribute above for why they exist, and `ci_gated_int_override/2` for
  the gating rule.
  """
  @spec drain_overrides() :: [{String.t(), {module(), atom()}}]
  def drain_overrides, do: @drain_overrides

  @doc """
  Decides whether an integer rate-limit override env var should be applied.

  These overrides exist only to stop CI/E2E stacks from 429-ing themselves; they
  must never weaken a limiter in production. Production task definitions never
  set `CI=true`, so gating on it makes a stray override (e.g. copy-pasted from a
  CI compose file into a prod task def) inert.

    * `{:ok, integer}`  — present and `CI=true`: apply it.
    * `{:ignored, raw}` — present but not in CI: do NOT apply; the caller logs.
    * `:none`           — absent or blank.

  `getenv` is a `(String.t() -> String.t() | nil)` (e.g. `&System.get_env/1`).
  """
  @spec ci_gated_int_override((String.t() -> String.t() | nil), String.t()) ::
          {:ok, integer()} | {:ignored, String.t()} | :none
  def ci_gated_int_override(getenv, var) when is_function(getenv, 1) and is_binary(var) do
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
