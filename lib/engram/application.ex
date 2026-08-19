defmodule Engram.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  # Compile-time, because `Mix` is not available at runtime in a release. Used
  # to keep boot-time operator warnings out of dev and test, where a plaintext
  # canonical URL is normal and correct.
  @release_build? Mix.env() == :prod

  @impl true
  def start(_type, _args) do
    Engram.Crypto.Config.validate!()
    verify_spa_integrity!()
    warn_if_refresh_cookie_insecure()
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
        # Bounds concurrent catch-up page builds. Absent, merged_changes_page
        # degrades open rather than failing, so ordering here is not critical.
        Engram.Sync.PageGate,
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
        # Owns the resident-room ETS table (#1152). Must start before any CRDT
        # room, since a drain-enabled room's timer touches it on init.
        Engram.Notes.CrdtRoomLru,
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
        maybe_warm_lang_models()
        {:ok, pid}

      other ->
        other
    end
  end

  # Pull the Lingua n-gram models into the NIF's process-global cache at boot.
  # They are loaded lazily on first detection and then shared by every caller on
  # the node, so without this the first note indexed after a deploy pays a ~55 MB
  # load on a DirtyCpu scheduler while a user waits on their sync.
  #
  # Runs async and unlinked on purpose: the load depends on nothing in the
  # supervision tree, and doing it inline would hold start/2 — and therefore the
  # Endpoint and the ECS health check — behind pure CPU work. LangDetect.classify/1
  # rescues internally, so a failure degrades to raw-token indexing, never a
  # crashed boot.
  defp maybe_warm_lang_models do
    # The spawned pid is deliberately dropped: nothing waits on the warmup and
    # nothing supervises it (see above), so there is no handle worth keeping.
    _ =
      if Application.get_env(:engram, :warm_lang_models, true) do
        {:ok, _pid} = Task.start(&Engram.KeywordIndex.LangDetect.warmup/0)
      end

    :ok
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

  # `LocalAuthController` derives the refresh cookie's `Secure` attribute from
  # the canonical URL, which is the only operator-declared statement of how
  # users actually reach this deployment (`conn.scheme` is always `:http`
  # behind a TLS-terminating edge, which is what shipped the cookie without
  # `Secure` in the first place).
  #
  # The gap that leaves: `config/runtime.exs` wraps the whole `url:` block in
  # `if phx_hosts do`, so an operator who never sets `PHX_HOST` falls back to
  # the `config/config.exs` default of `http://localhost` and gets
  # `secure: false` — even if they are, in fact, behind Caddy or nginx doing
  # TLS. That is a supported shape, so this cannot fail closed without breaking
  # genuine plaintext LAN deployments. It CAN refuse to be silent about it.
  #
  # Read from application env rather than `EngramWeb.Endpoint.url/0`: the
  # endpoint is started further down in `children` and its persistent_term is
  # not warmed yet at this point in boot.
  #
  # Only fires where the cookie actually exists (local credentials, i.e.
  # self-host) and only in a release build, so dev and test stay quiet.
  defp warn_if_refresh_cookie_insecure do
    scheme =
      :engram
      |> Application.get_env(EngramWeb.Endpoint, [])
      |> Keyword.get(:url, [])
      |> Keyword.get(:scheme, "http")

    if @release_build? and Engram.Auth.supports_credentials?() and scheme != "https" do
      Logger.warning("""
      refresh_token cookie will be issued WITHOUT the Secure attribute.

      The canonical URL is #{scheme}://…, so Engram assumes it is reached over
      plaintext. If that is right (a LAN box with no TLS), nothing is wrong.

      If you are actually behind a TLS reverse proxy, this is a real exposure:
      a 30-day refresh token that a downgrade can replay over cleartext. The
      app cannot detect this on its own, because TLS terminates at your proxy
      and every request arrives here as plain HTTP.

      Fix: set PHX_HOST (and PHX_SCHEME=https if you do not want the prod
      default). See .env.example.
      """)
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
            # Sync/CRDT errors are vault-scoped; without this a Sentry event for a
            # failed index checkpoint cannot say WHICH vault lost its snapshot.
            :vault_id,
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
