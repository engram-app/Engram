defmodule Engram.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Engram.Crypto.Config.validate!()
    install_log_redaction_filter()
    EngramWeb.RequestLogger.attach()

    children =
      [
        EngramWeb.Telemetry,
        Engram.Repo,
        boot_canary_task(),
        {DNSCluster, query: Application.get_env(:engram, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Engram.PubSub},
        EngramWeb.Presence,
        Engram.Crypto.DekCache,
        {Oban, Application.fetch_env!(:engram, Oban)},
        clerk_strategy_child(),
        EngramWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Engram.Supervisor]
    Supervisor.start_link(children, opts)
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

  # T3.5.5 / M3 — boot canary verification. Runs immediately after Repo
  # comes up. A transient task that exits 0 on success and crashes the
  # supervisor on failure (which crashes the application start, so the
  # node fails loudly on a wrong master key). Skipped in :test where
  # the canary table is per-sandbox; tests cover BootCanary directly.
  # Restart `:temporary` so a verify!/0 raise propagates immediately to
  # `Application.start/2` rather than triggering the supervisor restart-
  # storm + 3 stack traces before max_restarts surfaces the failure.
  defp boot_canary_task do
    if Application.get_env(:engram, :boot_canary_enabled, true) do
      %{
        id: :engram_boot_canary,
        start: {Task, :start_link, [&Engram.Crypto.BootCanary.verify!/0]},
        restart: :temporary,
        type: :worker
      }
    end
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
