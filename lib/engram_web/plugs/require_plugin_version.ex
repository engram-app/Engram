defmodule EngramWeb.Plugs.RequirePluginVersion do
  @moduledoc """
  Halts with `426 Upgrade Required` when the caller reports an Obsidian-plugin
  version below `Engram.PluginVersion.minimum/0`. Absent or unreadable header
  passes — see that module for the full rationale, including why everything
  unknown is allowed and why this is not a security control.

  This is the HTTP half only. Sync runs over CRDT/sync channels where a Plug
  never runs, so `EngramWeb.ChannelGate.check/3` enforces the same floor on
  join. Adding this plug to a pipeline does not gate sockets.

  Placement in `:authed_api`: after `AccountDeleted`, before everything else.
  A deleted account is terminal and wins, but telling a user to finish
  onboarding or fix their subscription is useless advice for a client that
  cannot speak the protocol — upgrade beats every remaining verdict.

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
    reported = conn |> get_req_header("x-plugin-version") |> List.first()
    conn = assign(conn, :plugin_version, reported)

    if PluginVersion.supported?(reported) do
      conn
    else
      Halt.json(conn, 426, %{
        error: "plugin_upgrade_required",
        min_version: PluginVersion.minimum(),
        # Safe to echo: `supported?/1` only returns false for a string it
        # successfully parsed as a version, which bounds both length and
        # alphabet. An arbitrary blob never reaches this branch.
        your_version: reported,
        update_url: PluginVersion.update_url()
      })
    end
  end
end
