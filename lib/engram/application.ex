defmodule Engram.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Engram.Crypto.Config.validate!()
    verify_spa_integrity!()
    install_log_redaction_filter()
    EngramWeb.RequestLogger.attach()
    Engram.Telemetry.ObanDiscardHandler.attach()

    children =
      [
        EngramWeb.Telemetry,
        Engram.Repo,
        boot_canary_guard(),
        {DNSCluster, query: Application.get_env(:engram, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Engram.PubSub},
        # Must start after PubSub (it subscribes in init) and before the
        # maybe_seed_legal/0 boot broadcast below, so this node's own subscriber
        # can't miss its boot-reseed eviction. Don't reorder above PubSub.
        Engram.Legal.VersionCache.Invalidator,
        EngramWeb.Presence,
        Engram.Crypto.DekCache,
        Engram.UsageMeters.ActivityCache,
        Engram.Onboarding.TermsCache,
        Engram.Auth.SignupRejections,
        rate_limiter_child(),
        {Oban, Application.fetch_env!(:engram, Oban)},
        clerk_strategy_child(),
        EngramWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: Engram.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        maybe_seed_legal()
        {:ok, pid}

      other ->
        other
    end
  end

  # Seed + verify terms_versions from the vendored manifest, then warm the
  # version cache. Skipped in :test (tests seed per-case). Fail-loud verify
  # runs in prod so a manifest/db drift halts boot instead of 409-ing signups.
  #
  # Also skipped in self-host (billing_enabled=false): the onboarding gate is
  # bypassed there, so seeding an unused legal table — and turning the vendored
  # manifest into a hard, fail-loud boot dependency — buys nothing. If a self-host
  # operator later enables billing, the seed runs on that boot.
  defp maybe_seed_legal do
    if Application.get_env(:engram, :seed_legal_on_boot, true) and
         Application.get_env(:engram, :billing_enabled, false) do
      Engram.Legal.Seeder.seed()
      Engram.Legal.Seeder.verify()
      Engram.Legal.VersionCache.invalidate_all()
    end
  end

  # T3-audit C2 — runs BootCanary.verify!/0 synchronously in a GenServer's
  # init/1, AFTER Engram.Repo has started (it queries `system_canaries`).
  # An init/1 raise → start_link returns {:error, _} → supervisor's
  # start_link fails → Application.start/2 fails → VM exits non-zero. True
  # fail-loud. The prior `Task.start_link` wiring returned {:ok, pid}
  # synchronously and lost the eventual raise to `:temporary`.
  defp boot_canary_guard do
    if Application.get_env(:engram, :boot_canary_enabled, true) do
      %{
        id: :engram_boot_canary_guard,
        start: {Engram.Crypto.BootCanaryGuard, :start_link, []},
        restart: :temporary
      }
    end
  end

  # Gated by config so test/dev (where vite serves the SPA separately,
  # no priv/static/app build to validate) don't have to maintain a fake
  # asset tree. runtime.exs enables it in :prod.
  defp verify_spa_integrity! do
    if Application.get_env(:engram, :spa_integrity_check_enabled, false) do
      Engram.SpaIntegrity.verify!()
    end
  end

  defp install_log_redaction_filter do
    # Idempotent: removing a missing filter is a no-op error we ignore so
    # repeated boots (and ExUnit's per-suite restart) don't crash.
    _ = :logger.remove_primary_filter(:engram_redact)

    :ok =
      :logger.add_primary_filter(
        :engram_redact,
        {&Engram.Logger.RedactFilter.filter/2, []}
      )
  end

  defp clerk_strategy_child do
    if Application.get_env(:engram, :auth_provider) == :clerk &&
         Application.get_env(:engram, :clerk_jwks_url) do
      {Engram.Auth.ClerkStrategy, time_interval: 60_000, first_fetch_sync: true}
    end
  end

  # Start the concrete limiter matching the configured backend. ETS (default)
  # needs only a clean_period; Redis needs connection opts (REDIS_URL, wired in
  # runtime.exs). Same release artifact, runtime-selected — see EngramWeb.RateLimiter.
  defp rate_limiter_child do
    case EngramWeb.RateLimiter.backend() do
      :redis ->
        opts = Application.get_env(:engram, EngramWeb.RateLimiter.Redis, [])
        {EngramWeb.RateLimiter.Redis, opts}

      _ets ->
        {EngramWeb.RateLimiter.ETS, [clean_period: :timer.minutes(2)]}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EngramWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
