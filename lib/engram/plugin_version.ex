defmodule Engram.PluginVersion do
  @moduledoc """
  The minimum Obsidian-plugin version this backend will talk to.

  ## Why the floor is a compile-time constant

  Not an env var, not a DB row, not an admin toggle. You need a floor at
  exactly one moment: you are deploying a backend that old clients can no
  longer talk to correctly. The floor is therefore a property of *this
  release*, and shipping it in the release means it can't drift between
  nodes, can't be forgotten in a task definition, and can't be set to a
  value that contradicts the code running next to it. Raising it is a
  one-line PR that goes out with the change that made it necessary.

  ## This is a compatibility gate, not a security control

  A client that wants past it just sends a higher number — the header is
  self-reported and unauthenticated. That is fine and deliberate: the gate
  exists to stop *honest* old clients from corrupting data against a
  protocol they don't speak, not to stop an attacker. Never put an
  entitlement, a quota, or an authorization decision behind it.

  ## Everything unreadable is ALLOWED

  Absent, empty, unparseable, over-long, non-binary — all pass. Two reasons:

    * Every client that exists today predates the header. Failing closed on
      absence bricks the entire installed base the moment this ships, plus
      the web SPA and every MCP client, none of which send it.
    * The header is attacker-controlled. `Version.parse/1` on an unbounded
      string is work an unauthenticated caller can ask for, so anything over
      `#{32}` bytes is refused a parse and waved through.

  The only thing that is ever blocked is a version we successfully parsed
  and found to be strictly below the floor.

  ## Enforcement seams

  Two, and adding one does not add the other:

    * `EngramWeb.Plugs.RequirePluginVersion` on the `:authed_api` pipeline
      (HTTP) → `426 Upgrade Required`.
    * `EngramWeb.ChannelGate.check/3` (sync + CRDT joins) →
      `plugin_upgrade_required`.

  The socket half is the load-bearing one. Sync runs over CRDT channels, so
  the HTTP plug alone would leave a "blocked" client happily syncing.
  """

  # Raise this in the same PR as the change that makes old clients wrong.
  # 1.28.0 is the version at which the plugin first shipped the header, so
  # this value is a deliberate no-op: nothing in the wild reports a version
  # yet, and everything unreported is allowed. It exists to prove the wiring.
  @minimum "1.28.0"

  # Obsidian's own plugin pane, which offers the Update button. A web URL
  # would send a mobile user to a page they can't install from.
  @update_url "obsidian://show-plugin?id=engram-vault-sync"

  # Longer than any real dot-triple with a pre-release tag, short enough that
  # parsing is free. See "Everything unreadable is ALLOWED".
  @max_len 32

  @spec minimum() :: String.t()
  def minimum, do: @minimum

  @spec update_url() :: String.t()
  def update_url, do: @update_url

  @doc """
  `false` only for a version we parsed and found below the floor.
  """
  @spec supported?(term()) :: boolean()
  def supported?(reported) when is_binary(reported) and byte_size(reported) <= @max_len do
    case Version.parse(String.trim(reported)) do
      # `compare/2` rather than `match?/2`: pure semver ordering, with no
      # opinion about whether a pre-release counts. 1.29.0-beta.1 is above
      # a 1.28.0 floor and below a 1.29.0 one, which is what we want.
      {:ok, version} -> Version.compare(version, @minimum) != :lt
      :error -> true
    end
  end

  def supported?(_), do: true
end
