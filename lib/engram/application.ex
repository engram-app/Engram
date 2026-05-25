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
        EngramWeb.Presence,
        Engram.Crypto.DekCache,
        Engram.UsageMeters.ActivityCache,
        Engram.Onboarding.TermsCache,
        {EngramWeb.RateLimiter, [clean_period: :timer.minutes(2)]},
        {Oban, Application.fetch_env!(:engram, Oban)},
        clerk_strategy_child(),
        EngramWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: Engram.Supervisor]
    Supervisor.start_link(children, opts)
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

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EngramWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
