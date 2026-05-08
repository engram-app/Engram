defmodule Engram.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    preflight!()
    install_log_redaction_filter()
    EngramWeb.RequestLogger.attach()

    children =
      [
        EngramWeb.Telemetry,
        Engram.Repo,
        {DNSCluster, query: Application.get_env(:engram, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Engram.PubSub},
        EngramWeb.Presence,
        Engram.Crypto.DekCache,
        {Oban, Application.fetch_env!(:engram, Oban)},
        clerk_strategy_child(),
        EngramWeb.Endpoint
      ]
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: Engram.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Synchronous pre-supervisor boot validation. A raise here propagates out
  of `Application.start/2` and the VM exits non-zero — true fail-loud.

  T3-audit C2 — the prior wiring put `BootCanary.verify!/0` inside a
  `Task.start_link` child with `restart: :temporary`. `start_link` returns
  `{:ok, pid}` synchronously the moment the task is spawned; any later
  raise inside `verify!/0` lands in the task process where `:temporary`
  causes the supervisor to log the EXIT and take no further action. Result:
  app boots with the wrong master key, defeating the whole point of M3.
  """
  def preflight! do
    Engram.Crypto.Config.validate!()

    if Application.get_env(:engram, :boot_canary_enabled, true) do
      Engram.Crypto.BootCanary.verify!()
    end

    :ok
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
