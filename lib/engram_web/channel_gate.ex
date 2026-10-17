defmodule EngramWeb.ChannelGate do
  @moduledoc """
  The socket-side equivalent of the vault-scoped router pipeline's access
  gates. Both `EngramWeb.SyncChannel` and `EngramWeb.CrdtChannel` call
  `check/3` from `join/3`.

  A Plug takes a `conn` and never runs on a socket, so every rule the pipeline
  enforces has to be re-expressed here or it silently does not apply to sync.

  ## What is mirrored, and what is NOT

  The vault scope pipes `:authed_api` (`router.ex:49-68`), which runs
  **twelve** plugs (`WebActivity` was added after `BumpActivity`; the deleted
  `EnforceSearchCap` once inflated an older count). Below in PIPELINE order, which is also the order
  `check/3` applies them; derive one from the other only in that order.

  Mirrored:

    * `AccountDeleted`            → `account_deleted` (`deleted_at` only) ✅ #1429
    * `RotationLockCheck`         → `rotation_in_progress` ✅ #1434
    * `RequireOnboarding`         → `onboarding_required` ✅ #1426
    * `RequireActiveSubscription` → `account_suspended` ✅ #1429
    * `BumpActivity`              → liveness stamp ✅ #1429 (see `## Activity`)
    * `RequirePluginVersion`      → `plugin_upgrade_required` ✅
    * `RequireApiRpsBudget`       → `api_access_not_available`, but ONLY the
      `cap == 0` case ✅ #1433

  **NOT mirrored — sockets are more permissive than HTTP here:**

    * `RequireApiRpsBudget`'s POSITIVE caps. `CrdtChannel.check_rate/2` is not
      a substitute: it uses fixed compile-time budgets per device and never
      reads the plan, so a key's 30 req/s REST budget is not the socket's.
      #1433.
    * `WebActivity`, analytics only (PostHog `:web` event for Clerk-session
      requests); not mirrored on join. `CrdtChannel` emits its own `:crdt`
      activity event instead, so there is no socket-side `:web` count.
    * `PreAuthRateLimit` (plug 1) — no equivalent, so there is **no join rate
      limiter at all**, which is why `check/3` sits behind the free topic
      ownership match.
    * `DeviceFingerprint` (4) — no equivalent.
    * `EnforceSearchCap` — DELETED, along with `Engram.Usage.SearchCap` (see
      `docs/context/mcp-bypasses-path-shaped-plugs.md`). The cap now lives in
      `Engram.Search` as a return value, not a plug. Listed only because two
      earlier versions of this doc counted it as a pipeline member and got the
      plug count wrong as a result. There is no channel search either way.

  (`Auth` (2) is not listed above because `UserSocket.connect/3` IS it. The
  arithmetic: 7 mirrored + 3 genuinely-not-mirrored (`PreAuthRateLimit`,
  `DeviceFingerprint`, `WebActivity`) + `Auth` = 11. `RequireApiWriteEnabled`
  used to be the twelfth, an open write gap on sockets; it was deleted in
  #1974 when API keys became every tier's, so the gap went with it.)

  `RequireActiveSubscription` collapses into the suspended check — since
  2026-06-07 it passes every tier (Free counts as active) and only rejects
  `suspended_at`. Note `AccountLifecycle` (a different, richer plug) is on the
  user-scoped and onboarding pipelines, NOT this one.

  **Adding a plug to `:authed_api` does not add it here.** Decide explicitly
  whether sync needs it, then either add it to `check/3` or add it to the NOT
  list above with a reason.

  ## Why the plugin-version floor is enforced here and not at `connect/3`

  Refusing the socket outright would be one line instead of a threaded
  parameter, and it would cover all three channels at once. It is wrong
  anyway: `connect/3` can only return `:error`, which reaches the client as an
  anonymous close carrying no payload. A blocked client would retry forever
  with nothing to show the user, which is the failure mode the whole feature
  exists to avoid. `check/3` returns a reason map, so the plugin can say
  "update the plugin" and stop.

  ## Why `user:` is not gated

  `EngramWeb.UserChannel` deliberately does NOT call this. It carries
  `vault_created` / `vault_populated` (the FTUX vault screen blocks on them)
  and `subscription_activated`, and no note content — only ids, names, and
  plan metadata.

  The justification is **suspension-specific**: a suspended user must be able
  to pay their way out, which is why `AccountLifecycle` allowlists
  `/api/billing/*`; `user:` is the socket equivalent. It does NOT extend to
  deleted accounts, for whom HTTP is terminal with no exemptions — a
  soft-deleted account can still join `user:` today. That is an open gap, not
  a decision: tracked in #1435.

  ## Activity

  A passing join also stamps `usage_meters.last_active_at` via
  `UsageMeters.touch_active/1` (debounced), mirroring
  `EngramWeb.Plugs.BumpActivity` on the HTTP side.

  This is not incidental — it is load-bearing for the gate above.
  `Engram.Workers.InactivityCleanup` soft-deletes Free accounts whose stamp
  has aged past the window, and that stamp was previously written ONLY by the
  request plug. A plugin user who syncs daily over CRDT and rarely touches
  REST therefore aged into the sweep while in constant active use. Before
  lifecycle was enforced here that was invisible (sync kept working); with it
  enforced, the same user would get a permanent `account_deleted` refusal on a
  live account. Porting the enforcement half of a pipeline without the
  liveness half turns a latent mis-classification into user-visible data loss.

  ## Freshness

  Lifecycle is read from a **fresh row on every join**, never from the socket's
  `current_user` (frozen at `connect/3`) and never from `Onboarding.GateCache`
  (a 60s PASS cache). An admin suspension must bite on the very next join:
  `SessionInvalidator` kills the live socket, but the JWT stays valid and the
  client reconnects within seconds.
  """

  alias Engram.Accounts
  alias Engram.Billing
  alias Engram.Crypto.HMAC
  alias Engram.Crypto.RotationGate
  alias Engram.Logger.Metadata
  alias Engram.Onboarding
  alias Engram.UsageMeters

  require Logger

  # Refusals `check/3` logs (#1430). See the clause that uses it.
  @logged_refusals ~w(account_suspended account_deleted)

  @doc """
  `:ok`, or `{:error, payload}` where `payload` is the map to return straight
  from `join/3` (always carries a `:reason`).
  """
  # `api_key` is MANDATORY, deliberately. It defaulted to nil, which made the
  # ungated arity the convenient one: `check(user)` compiled, passed dialyzer
  # and looked complete while silently skipping the Pricing v2 §G join gate —
  # the identical fail-open shape this module exists to prevent one layer up.
  # Pass `socket.assigns[:current_api_key]`; nil is the JWT case.
  #
  # `plugin_version` is mandatory for the same reason: an optional third
  # argument would make `check(user, key)` the convenient call that compiles,
  # passes dialyzer, and silently skips the compatibility floor. Pass
  # `socket.assigns[:plugin_version]`; nil (every client that predates the
  # param, plus the web SPA) is allowed.
  @spec check(Engram.Accounts.User.t(), term(), String.t() | nil) :: :ok | {:error, map()}
  def check(%Engram.Accounts.User{id: user_id} = user, api_key, plugin_version) do
    case do_check(user, api_key, plugin_version) do
      :ok ->
        :ok

      {:error, %{reason: reason}} = refused when reason in @logged_refusals ->
        # #1430: these were silent, so a client stuck behind one (the SPA
        # holds writes that never land) left no server-side trace. Only the
        # account-terminal reasons: `onboarding_required` already logs in
        # `Onboarding`, and the rest are transient or loop by design (see
        # KNOWN TRADE-OFF), so logging them would flood Loki on every rejoin.
        Logger.warning(
          "channel join refused: #{reason}",
          Metadata.with_category(:warning, :lifecycle,
            user_id: HMAC.hash_user_id(to_string(user_id)),
            reason: reason
          )
        )

        refused

      refused ->
        refused
    end
  end

  defp do_check(%Engram.Accounts.User{id: user_id}, api_key, plugin_version) do
    # One read, shared by both checks — `gate/2` is told not to re-read.
    #
    # No `|| socket_user` fallback: `Accounts.Lifecycle.hard_delete/2` removes
    # the row outright, and falling back to the socket's frozen `current_user`
    # would be fail-OPEN — that struct predates the deletion and carries no
    # `deleted_at`, so a purged account with a still-valid JWT would keep
    # syncing. HTTP fails closed here (`Plugs.Auth` cannot resolve a missing
    # user and 401s); the socket must not be more permissive.
    case Accounts.get_user(user_id) do
      nil ->
        {:error, %{reason: "account_deleted"}}

      fresh ->
        # Precedence mirrors `:authed_api` exactly (router.ex:52-56):
        # AccountDeleted -> RotationLockCheck -> RequireOnboarding ->
        # RequireActiveSubscription. Suspension therefore comes AFTER
        # onboarding, so an account suspended mid-signup reports the same
        # reason on both transports. Rotation re-reads the lock (see
        # rotation/1).
        # `RequirePluginVersion` is NOT here — it sits after the liveness
        # stamp below, mirroring router.ex:65. See the note there.
        with :ok <- deleted(fresh),
             :ok <- rotation(fresh),
             :ok <- onboarding(fresh),
             :ok <- suspended(fresh) do
          # Liveness stamp sits HERE, between the account gates and the API
          # gates, because that is where `BumpActivity` sits on HTTP
          # (router.ex:57, ahead of `RequireApiRpsBudget` at :66). A Pro user
          # with a PAT integration who downgrades to Free is stamped on every
          # REST call before being refused; stamping after `api_access/2`
          # would leave the socket silent and let `InactivityCleanup` sweep an
          # account generating daily traffic on both transports.
          #
          # It therefore fires when the ACCOUNT passes, not when the join
          # ultimately succeeds — a join later refused for `vault_not_found`
          # still stamps, exactly as an HTTP request to a missing vault does
          # (BumpActivity runs before VaultPlug).
          #
          # KNOWN TRADE-OFF: a Free PAT is refused at `api_access/2` on every
          # join, so an abandoned install reconnecting in a loop keeps its own
          # account looking active and `InactivityCleanup` never sweeps it.
          # HTTP bounds that loop with `PreAuthRateLimit` (plug #1); the socket
          # has no join limiter. Accepted deliberately: the opposite error is
          # soft-DELETING a blocked-but-active account, and data loss beats a
          # stale row. Revisit if a join limiter lands.
          stamp_activity(user_id)

          # AFTER the stamp, mirroring `RequirePluginVersion` sitting after
          # `BumpActivity` on HTTP — and for the identical reason the KNOWN
          # TRADE-OFF above gives: refusing a join without stamping would let
          # `InactivityCleanup` soft-delete an account that is syncing daily
          # and merely running an old plugin. Data loss beats a stale row.
          with :ok <- plugin_version(plugin_version) do
            api_access(fresh, api_key)
          end
        end
    end
  end

  @doc """
  Deletion-only check, for `user:`.

  `user:` is exempt from suspension and onboarding on purpose (see the
  moduledoc) but NOT from deletion: `AccountDeleted`'s clause runs ahead of
  the suspension allowlist and HTTP is terminal for a deleted account —
  "410 Gone on every endpoint, no exemptions". A purged row counts as deleted.
  """
  @spec check_not_deleted(Engram.Accounts.User.t()) :: :ok | {:error, map()}
  def check_not_deleted(%Engram.Accounts.User{id: user_id}) do
    case Accounts.get_user(user_id) do
      nil -> {:error, %{reason: "account_deleted"}}
      %{deleted_at: %DateTime{}} -> {:error, %{reason: "account_deleted"}}
      %{deleted_at: nil} -> :ok
    end
  end

  @doc """
  The vault scope of a socket's credential as it stands NOW, or `:revoked`.

  The socket read its OAuth grant once, at connect. A revoke or access edit
  disconnects the owner's sockets (`Engram.OAuth.grants_changed/1`), but no
  join may rely on that broadcast having landed: this re-resolves the grant
  (`gid`) from the `:oauth_grant` cache (one indexed query on a miss), so a
  revoked grant is refused and a vault is judged on what the grant reaches
  now. Every channel that judges a vault calls this, not
  `Permissions.vault_scope/1` on the connect-time assigns. API keys are read
  fresh by `Permissions.vault_scope/1` itself (cached, evicted on edit).
  """
  @spec vault_scope(map()) :: Engram.Permissions.scope() | :revoked
  def vault_scope(%{oauth_claims: %{"gid" => _} = claims} = assigns) do
    case Engram.OAuth.expand_claims(claims) do
      {:ok, fresh} ->
        assigns
        |> Map.merge(%{
          oauth_scope_vault_ids: Engram.Permissions.scope_ids_from_claims(fresh),
          oauth_access: Engram.Permissions.from_claims(fresh)
        })
        |> Engram.Permissions.vault_scope()

      :revoked ->
        :revoked
    end
  end

  def vault_scope(assigns), do: Engram.Permissions.vault_scope(assigns)

  @doc """
  What a joined `sync:` or `crdt:` channel does when its credential no longer
  reaches the vault (`vault_scope/1`, re-read on every inbound frame and
  outbound push). The access change already broadcast a disconnect, but that
  is best-effort; the channel that noticed sends it again, so the socket
  closes, the client reconnects and its rejoin gets the join's own refusal.
  Stopping only the channel is not enough: the plugin has no per-topic
  rejoin and would keep talking to a dead topic. Returns the channel's stop.
  """
  @spec access_lost(Phoenix.Socket.t()) ::
          {:stop, {:shutdown, :access_changed}, Phoenix.Socket.t()}
  def access_lost(%Phoenix.Socket{assigns: %{current_user: %{id: user_id}}} = socket) do
    :ok = Engram.Auth.SessionInvalidator.disconnect_user(to_string(user_id))
    {:stop, {:shutdown, :access_changed}, socket}
  end

  # Each of these matches STRICTLY on the field it gates rather than falling
  # through a `_user` catch-all, so a renamed or retyped column CRASHES here
  # instead of silently passing every account. Same argument
  # `Onboarding.derive_gate/3` makes about its destructuring.
  #
  # This does NOT protect against a narrowed read. Ecto materialises
  # unselected columns as nil, so a `select:`-projected `get_user/1` yields
  # `%User{deleted_at: nil, suspended_at: nil}` and both clauses match
  # cleanly — every suspended and soft-deleted account would pass, with no
  # crash and no test failure. `check/3` must keep loading the FULL row; if
  # the join cost ever motivates a narrower query, gate on a column list, not
  # on these clauses.
  defp deleted(%{deleted_at: %DateTime{}}), do: {:error, %{reason: "account_deleted"}}
  defp deleted(%{deleted_at: nil}), do: :ok

  defp suspended(%{suspended_at: %DateTime{}}), do: {:error, %{reason: "account_suspended"}}
  defp suspended(%{suspended_at: nil}), do: :ok

  # The socket half of `EngramWeb.Plugs.RequirePluginVersion`. Carries the
  # same three recovery fields as the 426 body — a client refused at join has
  # no working REST call left to go ask why.
  defp plugin_version(reported) do
    if Engram.PluginVersion.supported?(reported) do
      :ok
    else
      {:error,
       %{
         reason: "plugin_upgrade_required",
         min_version: Engram.PluginVersion.minimum(),
         your_version: reported,
         update_url: Engram.PluginVersion.update_url()
       }}
    end
  end

  # Best-effort, and deliberately so. This is a DB WRITE on a path that was
  # read-only: an exception here would propagate out of `join/3`, kill the
  # channel process, and hand the client a transport error rather than a gate
  # reason — which it then retries, re-attempting the same write. Refusing to
  # sync because we could not record "you were here" is the wrong coupling.
  #
  # Logged rather than swallowed, because a persistently failing stamp is not
  # cosmetic: `InactivityCleanup` reads this column to decide who gets
  # soft-deleted, so silent failure re-creates the very lockout #1429 exists
  # to prevent. It has to be alertable.
  #
  # `:lifecycle`, not `:database` — there is no `:database` category and
  # `with_category/3` RAISES on an unknown atom, so the first version of this
  # handler blew up inside the rescue and killed the join it exists to save.
  # `:reason`, not `:error`, because only allowlisted metadata keys are
  # emitted. `safe_reason/1` / `safe_exit_reason/1` because a raw
  # `%Postgrex.Error{}` renders "Failing row contains (...)" — a row value in
  # a log line whose user_id is HMAC-hashed precisely to avoid that.
  defp stamp_activity(user_id) do
    UsageMeters.touch_active(user_id)
  rescue
    e ->
      Logger.error(
        "activity stamp failed",
        Metadata.with_category(:error, :lifecycle,
          user_id: HMAC.hash_user_id(to_string(user_id)),
          reason: Metadata.safe_reason(e)
        )
      )

      :ok
  catch
    # `rescue` does not catch exits, and a DBConnection checkout timeout exits
    # rather than raising — the single most likely failure here.
    kind, reason ->
      Logger.error(
        "activity stamp exited",
        Metadata.with_category(:error, :lifecycle,
          user_id: HMAC.hash_user_id(to_string(user_id)),
          reason_label: to_string(kind),
          reason: Metadata.safe_exit_reason(reason)
        )
      )

      :ok
  end

  # Mirrors `RequireApiRpsBudget` (#1433). Every tier's `api_rps_cap` is 30
  # since #1974, so this refuses only a per-user override of 0: the kill
  # switch that stops a key over REST must stop it over the sync socket too,
  # or the socket reads the whole vault the REST API just refused.
  #
  # The exemption keys on the key being non-nil, NOT on the assign existing.
  # The plug uses `not is_map_key(assigns, :current_api_key)`, but
  # `UserSocket.accept/4` ALWAYS sets that key (nil for JWT) — porting the
  # guard literally would gate every web and plugin user on the platform.
  #
  # ONLY the `cap == 0` half is mirrored. `CrdtChannel.check_rate/2` is NOT
  # the socket's `api_rps_cap`: it uses fixed compile-time budgets per device
  # and never reads the plan. See the NOT-mirrored list above.
  defp api_access(_user, nil), do: :ok

  defp api_access(user, _api_key) do
    case Billing.effective_limit(user, :api_rps_cap) do
      0 -> {:error, %{reason: "api_access_not_available", upgrade_url: "/#settings/billing"}}
      _ -> :ok
    end
  end

  # `check/1`, not `check_user/1` (#1341): the row above comes from the
  # `:user` cache, which learns of a lock taken on another node only when its
  # eviction lands, and a joined socket encrypts. One query per join.
  # `SyncChannel` had no check at all before this gate (#1434).
  defp rotation(user) do
    case RotationGate.check(user.id) do
      :ok -> :ok
      {:error, :rotation_in_progress} -> {:error, %{reason: "rotation_in_progress"}}
      {:error, :user_not_found} -> {:error, %{reason: "account_deleted"}}
    end
  end

  defp onboarding(user) do
    case Onboarding.gate(user, fresh: true) do
      :ok ->
        :ok

      {:error, missing, next_step} ->
        {:error, %{reason: "onboarding_required", missing: missing, next_step: next_step}}
    end
  end
end
