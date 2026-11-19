defmodule EngramWeb.Plugs.RequirePluginVersion do
  @moduledoc """
  Halts with `426 Upgrade Required` when the caller reports an Obsidian-plugin
  version below `Engram.PluginVersion.minimum/0`, or reports none while its
  user agent names the Obsidian app (a plugin older than the header). Any other
  absent or unreadable header passes — see that module for the full rationale,
  including why everything else unknown is allowed and why this is not a
  security control.

  This is the HTTP half only. Sync runs over CRDT/sync channels where a Plug
  never runs, so `EngramWeb.ChannelGate.check/3` enforces the same floor on
  join. Adding this plug to a pipeline does not gate sockets.

  Placement in `:authed_api`: after `BumpActivity`, i.e. LAST of the account
  gates. An earlier position gave a nicer message — upgrade beating "finish
  onboarding", which is useless advice for a client that cannot speak the
  protocol — and cost liveness. A refused request never reaches `BumpActivity`,
  so it never stamps `last_active_at`, and `InactivityCleanup` soft-deletes at
  90 days: a user syncing daily on an old plugin would be deleted for being
  blocked. `ChannelGate` already refuses that trade for `api_access/2` in as
  many words, "data loss beats a stale row". Message precedence is worth less.

  The version is assigned whether or not the request is refused. It is read by
  nothing today; it exists so a refusal is attributable in a debugger and so a
  future consumer has a conn key rather than a re-read header. The tracked
  signal for "who is on what version" is the `ws connect` log line
  (`EngramWeb.UserSocket`), which costs one field per socket rather than one
  per request — and which lands in CloudWatch, not Loki.
  """

  import Plug.Conn

  alias Engram.PluginVersion
  alias EngramWeb.Plugs.Halt

  def init(opts), do: opts

  def call(conn, _opts) do
    reported =
      conn |> get_req_header("x-plugin-version") |> List.first() |> PluginVersion.reported()

    conn = assign(conn, :plugin_version, reported)
    obsidian? = conn |> get_req_header("user-agent") |> PluginVersion.obsidian_client?()

    if PluginVersion.supported?(reported, obsidian?) do
      conn
    else
      # `your_version` is safe to echo: it is nil (absent) or a string
      # `supported?/1` successfully parsed as a version, which bounds both
      # length and alphabet. An arbitrary blob never reaches this branch.
      Halt.json(
        conn,
        426,
        Map.put(PluginVersion.recovery_fields(reported), :error, "plugin_upgrade_required")
      )
    end
  end
end
