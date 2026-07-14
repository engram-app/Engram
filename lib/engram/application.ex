defmodule Engram.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Engram.Crypto.Config.validate!()
    verify_spa_integrity!()
    install_log_redaction_filter()
    # Sentry logger handler must attach AFTER the redaction filter so
    # error logs sent to Sentry have already had secrets scrubbed by
    # EngramWeb.RedactFilter. No-op when :sentry has no DSN configured.
    attach_sentry_logger_handler()
    EngramWeb.RequestLogger.attach()
    Engram.Telemetry.ObanDiscardHandler.attach()

    if Engram.Observability.Otel.enabled?(), do: Engram.Observability.Otel.attach_handlers()

    children =
      [
        EngramWeb.Telemetry,
        Engram.PromEx,
        Engram.Repo,
        boot_canary_guard(),
        {DNSCluster, query: Application.get_env(:engram, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Engram.PubSub},
        # Subscribes to CacheSync in init, so it must start after PubSub. (Local
        # eviction is synchronous in invalidate_all/0; this subscriber only
        # matters for evictions broadcast by already-clustered peer nodes.)
        Engram.Legal.VersionCache.Invalidator,
        EngramWeb.Presence,
        Engram.Crypto.DekCache,
        Engram.UsageMeters.ActivityCache,
        Engram.Usage.DailyCap.Cache,
        Engram.KeywordIndex.Stats.Cache,
        Engram.Onboarding.TermsCache,
        # Subscribe to CacheSync in init → must start after PubSub.
        Engram.Onboarding.GateCache,
        # Dedicated LISTEN/NOTIFY connection — OverrideCache LISTENs on it
        # so raw-SQL override writes (trigger → pg_notify) evict caches on
        # every node. Must start before OverrideCache.
        pg_notifications_child(),
        Engram.Billing.OverrideCache,
        # Resolved-entitlement cache (tier + full LimitKeys matrix), keyed by
        # user. Also LISTENs on user_limit_overrides_changed, so it must start
        # after pg_notifications_child like OverrideCache.
        Engram.Billing.EntitlementCache,
        Engram.Auth.SignupRejections,
        rate_limiter_child(),
        {Oban, Application.fetch_env!(:engram, Oban)},
        clerk_strategy_child(),
        # Bounds concurrent inline unbind checkpoints (self-healing via monitors);
        # must start before any CRDT room can terminate and call unbind/3.
        Engram.Notes.CheckpointGate,
        Engram.Notes.FanoutPacer,
        # One DynamicSupervisor owns all live CRDT doc rooms. Rooms are
        # cluster-wide singletons via :global; this supervisor is the local
        # owner when a room is started on this node (see CrdtRegistry).
        {DynamicSupervisor, name: Engram.Notes.CrdtDocSupervisor, strategy: :one_for_one},
        # Pyroscope continuous CPU profiler. Returns nil when GRAFANA_PYROSCOPE_URL
        # is unset (dev, test, self-host), and Enum.reject below filters it out.
        pyroscope_child(),
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

  # Attach Sentry's :logger handler. When :sentry has no DSN configured
  # (dev, test, self-host) the handler is a no-op — every report is
  # short-circuited before any network call, so attaching is safe everywhere.
  # Idempotent against ExUnit's per-suite restart for the same reason as the
  # redact filter above.
  #
  # Metadata allowlist controls cardinality on the Sentry side — every key
  # here is one that may appear on `Logger.error/2` calls we want surfaced
  # (paddle webhook, paddle reconcile, crypto rotation, request context).
  defp attach_sentry_logger_handler do
    _ = :logger.remove_handler(:engram_sentry)

    :ok =
      :logger.add_handler(:engram_sentry, Sentry.LoggerHandler, %{
        config: %{
          metadata: [
            :category,
            :drift_kind,
            :error_kind,
            :event_id,
            :event_type,
            :file,
            :function,
            :kind,
            :line,
            :module,
            :note_id,
            :paddle_price_id,
            :paddle_subscription_id,
            :queue,
            :reason,
            :reason_label,
            :request_id,
            :route,
            :status,
            :user_id,
            :worker
          ]
        }
      })
  end

  defp clerk_strategy_child do
    if Application.get_env(:engram, :auth_provider) == :clerk &&
         Application.get_env(:engram, :clerk_jwks_url) do
      {Engram.Auth.ClerkStrategy, time_interval: 60_000, first_fetch_sync: true}
    end
  end

  # Continuous BEAM CPU profiler. Started only when the three SOPS-wired
  # env vars (GRAFANA_PYROSCOPE_URL/USERNAME + GRAFANA_AGENT_TOKEN) are
  # all present at runtime — see config/runtime.exs. Dev/test/self-host
  # leave them unset and the supervisor never sees the child.
  defp pyroscope_child do
    if Engram.Observability.Pyroscope.configured?() do
      Engram.Observability.Pyroscope
    end
  end

  # One LISTEN/NOTIFY connection per node, shared by caches that subscribe
  # to Postgres triggers (OverrideCache today). auto_reconnect re-LISTENs
  # after a connection blip — Postgrex re-establishes the subscriptions on
  # reconnect for listeners registered via listen/3.
  defp pg_notifications_child do
    opts =
      Engram.Repo.config()
      |> Keyword.take([
        :hostname,
        :host,
        :port,
        :username,
        :password,
        :database,
        :ssl,
        :ssl_opts,
        :socket_options,
        :url
      ])
      |> Keyword.merge(name: Engram.PgNotifications, auto_reconnect: true, sync_connect: false)

    {Postgrex.Notifications, opts}
  end

  # Start the concrete limiter matching the configured backend. Both ETS backends
  # need only a clean_period. Same release artifact, runtime-selected — see
  # EngramWeb.RateLimiter.
  @doc false
  def rate_limiter_child do
    case EngramWeb.RateLimiter.backend() do
      :distributed_ets ->
        {EngramWeb.RateLimiter.DistributedETS, [clean_period: :timer.minutes(2)]}

      _ets ->
        {EngramWeb.RateLimiter.ETS, [clean_period: :timer.minutes(2)]}
    end
  end

  @impl true
  def prep_stop(state) do
    # Only drain when actually clustered (SaaS prod). Peer disconnect happens
    # in stop/1 — AFTER the endpoint's socket/HTTP drain — so WS clients on
    # the dying node keep cross-node fan-out until they've reconnected away.
    if Application.get_env(:engram, :dns_cluster_query) do
      Engram.Drainer.drain()
    end

    state
  end

  @impl true
  def stop(_state) do
    # Runs after the supervision tree (endpoint included) has stopped: safe
    # to leave the cluster now, and survivors observe a clean nodedown
    # before the VM exits.
    if Application.get_env(:engram, :dns_cluster_query) do
      Engram.Drainer.disconnect_peers()
    end

    :ok
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EngramWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
