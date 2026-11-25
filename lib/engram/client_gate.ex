defmodule Engram.ClientGate do
  @moduledoc """
  The ONE verdict for "may this client talk to us right now", shared by HTTP
  (`EngramWeb.Plugs.RequireAccountNotPaused`, `EngramWeb.Plugs.RequirePluginVersion`)
  and socket join (`EngramWeb.ChannelGate`). MCP rides the HTTP pipeline, so it
  is covered by the same plugs.

  Two refusals, one body shape (`reason` plus the recovery fields):

    * `account_paused`: the user is quarantined, by an `account_paused` row in
      `user_limit_overrides` (`Engram.Admin.ClientLocks`) OR an unexpired
      `paused_accounts` flag entry (`Engram.ServiceConfig.Flags`). HTTP 403.
    * `plugin_upgrade_required` — below `Engram.PluginVersion.floor/0`
      (compile-time floor, raised by an optional runtime lock). HTTP 426.

  Cost per request: two cached ETS reads (the user's override entry and the
  service-override table), no query on a hit. Staleness: an admin write evicts
  every node at once (`CacheSync`); a lost eviction is bounded by the 60 s
  (override) / 15 s (floor) TTLs.

  Callers MUST run this AFTER the liveness stamp (`BumpActivity` /
  `UsageMeters.touch_active/1`): a refused user still counts as active, or
  `InactivityCleanup` would delete a paused account at 90 days.
  """

  alias Engram.Billing
  alias Engram.Billing.LimitKeys
  alias Engram.PluginVersion
  alias Engram.ServiceConfig.Flags

  @type refusal :: %{required(:reason) => String.t(), optional(atom()) => term()}

  @doc "Paused, then plugin version. `reported`/`obsidian?` as `PluginVersion.supported?/2`."
  @spec check(Engram.Accounts.User.t(), term(), boolean()) :: :ok | {:error, refusal()}
  def check(user, reported, obsidian?) do
    with :ok <- paused(user), do: plugin_version(reported, obsidian?)
  end

  # Takes anything with an `:id` (the +61 s worker has only the id). No @spec:
  # the honest one (`%{id: binary, ...} :: :ok | {:error, %{reason: <<_::112>>}}`)
  # is narrower than any spec worth writing (dialyzer :underspecs), the same
  # reason `Overrides.list/0` carries none.
  def paused(user) do
    if Flags.paused?(user.id) or
         Billing.control_override(user, LimitKeys.account_paused()) == true,
       do: {:error, %{reason: "account_paused"}},
       else: :ok
  end

  @spec plugin_version(term(), boolean()) :: :ok | {:error, refusal()}
  def plugin_version(reported, obsidian?) do
    # ONE read of the minimum feeds both the verdict and the body.
    floor = PluginVersion.effective_minimum()

    if PluginVersion.supported?(reported, obsidian?, floor),
      do: :ok,
      else:
        {:error,
         Map.put(
           PluginVersion.recovery_fields(reported, floor),
           :reason,
           "plugin_upgrade_required"
         )}
  end

  @doc "The HTTP status of a refusal reason."
  @spec http_status(String.t()) :: 403 | 426
  def http_status("account_paused"), do: 403
  def http_status("plugin_upgrade_required"), do: 426
end
