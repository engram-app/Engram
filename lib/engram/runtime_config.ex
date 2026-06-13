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
    ci_gated_override(getenv, "RATE_LIMIT_AUTH_OVERRIDE")
  end

  @doc """
  Same CI-gated contract as `rate_limit_auth_override/1`, for the pre-auth
  (vault-pipeline) limiter via `PRE_AUTH_RATE_LIMIT_OVERRIDE`. Needed so bulk
  e2e flows (e.g. the protocol-rev bulk-push test) can lift the default
  600/min `/api/notes` cap without 429-ing themselves; production never sets
  `CI=true`, so it can't weaken the limiter there.
  """
  @spec pre_auth_rate_limit_override((String.t() -> String.t() | nil)) ::
          {:ok, integer()} | {:ignored, String.t()} | :none
  def pre_auth_rate_limit_override(getenv) when is_function(getenv, 1) do
    ci_gated_override(getenv, "PRE_AUTH_RATE_LIMIT_OVERRIDE")
  end

  defp ci_gated_override(getenv, var) do
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
end
