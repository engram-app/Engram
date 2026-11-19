defmodule Engram.Admin.ClientLocks do
  @moduledoc """
  Operator commands to lock down a bad plugin version or quarantine one user,
  and to REVERSE both. Callable from a release shell:

      bin/engram rpc 'Engram.Admin.ClientLocks.lock_plugin_version("1.41.0", "1.41.0", 86_400, "1.40.x floods /api/logs", by: "todd")'
      bin/engram rpc 'Engram.Admin.ClientLocks.lift_plugin_lock(by: "todd")'
      bin/engram rpc 'Engram.Admin.ClientLocks.quarantine_user("<uuid>", "log loop", 3600, by: "todd")'
      bin/engram rpc 'Engram.Admin.ClientLocks.lift_quarantine("<uuid>", by: "todd")'
      bin/engram rpc 'Engram.Admin.ClientLocks.list_locks()'

  `update_to` is checked against the plugin repo's published manifest
  (`latest_published/0`, fetched at command time, never on a request): above
  it, or an unreachable manifest, needs `confirm: true`. The operator's own
  input is never the reference.

  ## Reversal is first class

    * Every lock REQUIRES an expiry (seconds, max 30 days) and is judged
      against the clock on every read: an expired lock is unlocked even if no
      one lifted it (`Engram.PluginVersion.floor/0`, `Billing.control_override/2`).
    * Lifts are idempotent, safe when nothing is locked, and take effect on all
      nodes at once: the write evicts every node's cache through `CacheSync`.
      Staleness bound if an eviction is lost: 15 s (floor), 60 s (quarantine).
    * A lift also drops the sockets that were refused (version below the lifted
      min, or the quarantined user's), so they rejoin and are admitted at once.
      A client latched by the plugin's paused mode otherwise resumes on its next
      probe: any `:authed_api` request (for example `GET /api/folders`) answers
      426/403 while refused and normally once lifted. Worst case without a socket
      reconnect: the plugin's hourly recheck (and `Retry-After: 3600`).

  ## What a lock cannot do

  A floor only reaches clients that REPORT a version (see `Engram.PluginVersion`).
  The number of recent devices a floor would block is NOT available: no table
  stores client versions (they exist only in the `ws connect` log line and
  Tempo `plugin.version`), so check Tempo before locking. Sockets already
  joined are dropped on a floor SET only if below the new min; a quarantine
  drops the user's sockets immediately and again at +61 s (the user-cache
  bound), because a rejoin can race the eviction.

  Every command writes one structured audit log line and a
  `client_lock_change_total{action}` counter increment.
  """

  import Ecto.Query

  alias Engram.Auth.SessionInvalidator
  alias Engram.Billing.LimitKeys
  alias Engram.Billing.OverrideCache
  alias Engram.Billing.UserLimitOverride
  alias Engram.Logger.Metadata
  alias Engram.PluginVersion
  alias Engram.Repo
  alias Engram.ServiceConfig
  alias Engram.Workers.QuarantineDisconnect

  require Logger

  @topic "client_gate"
  @max_expiry_s 30 * 86_400
  @reason_max 200
  # One more than the 60 s `:billing_override` TTL (the review's H2 bound).
  @second_disconnect_s 61

  @doc "PubSub topic every `user:` channel listens on for floor changes."
  def topic, do: @topic

  @spec lock_plugin_version(String.t(), String.t(), pos_integer(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def lock_plugin_version(min, update_to, expires_in_s, reason, opts \\ []) do
    now = DateTime.utc_now()

    value = %{
      "min" => min,
      "update_to" => update_to,
      "expires_at" => now |> DateTime.add(expires_in_s || 0, :second) |> DateTime.to_iso8601(),
      "reason" => reason
    }

    switch_was_off = ServiceConfig.get(:plugin_floor_enabled, true) != true

    with :ok <- check_expiry(expires_in_s),
         {:ok, lock} <- valid_lock(value),
         :ok <- above_compiled(lock.min),
         :ok <- published(update_to, opts),
         :ok <- ServiceConfig.override(:plugin_floor, value, by: opts[:by]),
         :ok <- ServiceConfig.override(:plugin_floor_enabled, true, by: opts[:by]) do
      audit("lock_plugin_version",
        min: min,
        update_to: update_to,
        expires_in_s: expires_in_s,
        reason: reason,
        reenabled_kill_switch: switch_was_off,
        by: opts[:by]
      )

      recheck(min)
    end
  end

  @spec lift_plugin_lock(keyword()) :: :ok
  def lift_plugin_lock(opts \\ []) do
    previous = PluginVersion.lock_state()
    :ok = ServiceConfig.clear(:plugin_floor, by: opts[:by])
    audit("lift_plugin_lock", was_set: previous.set?, min: previous[:min], by: opts[:by])
    # Drop the clients that were refused so they rejoin and are admitted now.
    if previous[:min], do: recheck(previous.min), else: :ok
  end

  @spec quarantine_user(Ecto.UUID.t(), String.t(), pos_integer(), keyword()) ::
          :ok | {:error, term()}
  def quarantine_user(user_id, reason, expires_in_s, opts \\ []) do
    with :ok <- check_expiry(expires_in_s),
         :ok <- check_reason(reason),
         %{} <- Engram.Accounts.get_user(user_id) || {:error, :user_not_found} do
      now = DateTime.utc_now(:second)

      attrs = %{
        user_id: user_id,
        key: LimitKeys.account_paused(),
        value: %{"v" => true},
        reason: reason,
        set_by: operator(opts),
        set_at: now,
        expires_at: DateTime.add(now, expires_in_s, :second)
      }

      %UserLimitOverride{}
      |> UserLimitOverride.changeset(attrs)
      |> Repo.insert(
        on_conflict: {:replace, [:value, :reason, :set_by, :set_at, :expires_at]},
        conflict_target: [:user_id, :key],
        skip_tenant_check: true
      )
      |> case do
        {:ok, _} ->
          :ok = OverrideCache.evict(user_id)

          audit("quarantine_user",
            user: user_id,
            expires_in_s: expires_in_s,
            reason: reason,
            by: opts[:by]
          )

          :ok = SessionInvalidator.disconnect_user(user_id)
          schedule_second_disconnect(user_id)

        {:error, cs} ->
          {:error, cs}
      end
    else
      {:error, _} = e -> e
    end
  end

  @spec lift_quarantine(Ecto.UUID.t(), keyword()) :: :ok
  def lift_quarantine(user_id, opts \\ []) do
    {n, _} =
      Repo.delete_all(
        from(o in UserLimitOverride,
          where: o.user_id == ^user_id and o.key == ^LimitKeys.account_paused()
        ),
        skip_tenant_check: true
      )

    :ok = OverrideCache.evict(user_id)
    audit("lift_quarantine", user: user_id, was_set: n > 0, by: opts[:by])
    # Forces the paused client to rejoin and be admitted now, not at its probe.
    SessionInvalidator.disconnect_user(user_id)
  end

  @doc "Everything locked now and when it self-reverses."
  @spec list_locks() :: %{plugin_floor: map(), quarantined: [map()]}
  def list_locks do
    now = DateTime.utc_now()

    quarantined =
      from(o in UserLimitOverride,
        where: o.key == ^LimitKeys.account_paused() and o.expires_at > ^now,
        order_by: o.expires_at,
        limit: 200,
        select: %{
          user_id: o.user_id,
          reason: o.reason,
          set_by: o.set_by,
          expires_at: o.expires_at
        }
      )
      |> Repo.all(skip_tenant_check: true)

    %{plugin_floor: PluginVersion.lock_state(), quarantined: quarantined}
  end

  # -- guards -----------------------------------------------------------------

  defp check_expiry(s) when is_integer(s) and s > 0 and s <= @max_expiry_s, do: :ok
  defp check_expiry(_), do: {:error, {:expiry_required, 1..@max_expiry_s}}

  defp check_reason(r) when is_binary(r) and byte_size(r) in 1..@reason_max, do: :ok
  defp check_reason(_), do: {:error, :reason_required}

  defp valid_lock(value) do
    case PluginVersion.parse_lock(value) do
      {:ok, lock} ->
        {:ok, lock}

      :error ->
        {:error, :invalid_lock_update_to_must_be_gte_min_plain_versions_and_reason_required}
    end
  end

  defp above_compiled(min) do
    if Version.compare(min, PluginVersion.compiled_minimum()) == :gt,
      do: :ok,
      else: {:error, {:min_not_above_compiled_floor, PluginVersion.compiled_minimum()}}
  end

  # A floor above every release that exists bricks every client with nothing
  # to install. The reference is the plugin repo's manifest, NOT operator
  # input; above it, or unverifiable, the lock needs `confirm: true`.
  defp published(update_to, opts) do
    verified =
      with {:ok, latest} <- latest_published(),
           {:ok, latest_v} <- Version.parse(latest) |> ok_or(:unparseable_manifest_version) do
        if Version.compare(update_to, latest_v) == :gt, do: {:above, latest}, else: :ok
      end

    case {verified, opts[:confirm] == true} do
      {:ok, _} -> :ok
      {_, true} -> :ok
      {why, false} -> {:error, {:update_to_not_verified_published, why, :pass_confirm_true}}
    end
  end

  defp ok_or({:ok, _} = ok, _), do: ok
  defp ok_or(_, reason), do: {:error, reason}

  @manifest_url "https://raw.githubusercontent.com/engram-app/Engram-obsidian/main/manifest.json"

  @doc """
  The newest published plugin version (the plugin repo's `manifest.json`, which
  release-please bumps on release). Operator-command time only; never called on
  a request path. Swappable via `:plugin_manifest_fetcher` for tests.
  """
  @spec latest_published() :: {:ok, String.t()} | {:error, term()}
  def latest_published do
    case Application.get_env(:engram, :plugin_manifest_fetcher) do
      fun when is_function(fun, 0) -> fun.()
      nil -> fetch_manifest()
    end
  end

  defp fetch_manifest do
    with {:ok, %{status: 200, body: body}} <-
           Req.get(
             @manifest_url,
             [receive_timeout: 5_000, retry: false, decode_body: false] ++
               Application.get_env(:engram, :plugin_manifest_req_options, [])
           ),
         {:ok, %{"version" => v}} when is_binary(v) <- Jason.decode(body) do
      {:ok, v}
    else
      other -> {:error, {:manifest_unavailable, Metadata.safe_reason(other)}}
    end
  rescue
    e -> {:error, {:manifest_unavailable, Metadata.safe_reason(e)}}
  end

  defp recheck(min) do
    Phoenix.PubSub.broadcast(Engram.PubSub, @topic, {:client_gate_recheck, min})
  end

  defp schedule_second_disconnect(user_id) do
    {:ok, _} =
      %{user_id: user_id}
      |> QuarantineDisconnect.new(schedule_in: @second_disconnect_s)
      |> Oban.insert()

    :ok
  end

  # Same cleaning as `ServiceConfig.Overrides`: a short identifier, never free text.
  defp operator(opts) do
    raw = opts[:by] || System.get_env("ENGRAM_OPERATOR") || "unknown"
    cleaned = String.replace(to_string(raw), ~r/[^A-Za-z0-9@._-]/, "")
    if cleaned == "", do: "unknown", else: String.slice(cleaned, 0, 64)
  end

  defp audit(action, fields) do
    :telemetry.execute([:engram, :client_lock, :change], %{count: 1}, %{action: action})

    detail =
      Enum.map_join(fields, " ", fn
        {:user, id} -> "user=#{Engram.Crypto.HMAC.hash_user_id(to_string(id))}"
        {:reason, r} -> "reason=#{inspect(String.slice(to_string(r), 0, @reason_max))}"
        {:by, by} -> "by=#{operator(by: by)}"
        {k, v} -> "#{k}=#{v}"
      end)

    Logger.warning("client lock #{action} #{detail}", Metadata.with_category(:warning, :data))
  end
end
