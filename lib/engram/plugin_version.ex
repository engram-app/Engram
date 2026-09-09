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

  ## Pre-release tags are DISCARDED, not ordered

  Comparison is on `{major, minor, patch}` only. Semver says
  `1.31.0-beta.3 < 1.31.0`, and using that ordering here would have broken the
  feature on its first real use.

  `engram-obsidian-sync/scripts/release-version.mjs` names a preview build
  after the release it is previewing: `betaVersion` emits `1.31.0-beta.3` and
  `prVersion` emits `1.31.0-pr.512.g876f2c2`, and `pr-build.yml` stamps that
  straight into the shipped `manifest.json`. So the builds that CONTAIN a
  protocol fix are named below the release that ships it. Under semver
  ordering, shipping `@minimum "1.31.0"` alongside plugin 1.31.0 would refuse
  every beta tester and every PR reviewer running a build that already has the
  fix — and send them to a plugin pane with nothing newer to install.

  Discarding the tag means `1.31.0-anything` satisfies a floor of `1.31.0`.
  The cost is that a pre-release is trusted as if it were its final release,
  which is correct here: these tags are builds OF that release, not guesses at
  it.

  ## What this can and cannot reach

  Fail-open-on-absence plus "reporting started at version R" means the gate's
  reachable range is `[R, floor)`. **Every client older than R is permanently
  exempt.** That is the opposite of the intuition — the oldest clients, the
  ones most likely to speak a protocol we have since changed, report nothing
  and are always allowed. Raising the floor cuts off recent clients and leaves
  the genuinely ancient ones syncing.

  So this protects nothing until reporting adoption is broadly complete. Check
  the distribution before assuming a raise will bite (see
  `engram-workspace/docs/context/plugin-version-floor.md`).

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
  #
  # A deliberate no-op today. Plugin 1.28.0 was ALREADY RELEASED when the
  # reporting change was written and does not send the header — that lands in
  # the next release — so nothing in the wild reports a version and everything
  # unreported is allowed. Do not read this value as "1.28.0 is supported and
  # 1.27 is not"; no client has been assessed at all yet.
  @minimum "1.28.0"

  # Obsidian's own plugin pane, which offers the Update button. A web URL
  # would send a mobile user to a page they can't install from.
  @update_url "obsidian://show-plugin?id=engram-vault-sync"

  # Longer than any real version this repo can emit, short enough that parsing
  # is free. The longest real shape is a PR build — `1.28.1-pr.512.g876f2c2`,
  # 22 bytes — leaving 10 bytes of headroom. Mind that headroom: over-length
  # fails OPEN and silently, so a version scheme that outgrows this disables
  # the floor with no signal. `plugin_version_test.exs` pins the real formats
  # against this bound for exactly that reason.
  @max_len 32

  # Release-precision floor: {major, minor, patch}, pre-release DISCARDED.
  @floor (fn ->
            v = Version.parse!(@minimum)
            {v.major, v.minor, v.patch}
          end).()

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
      {:ok, %Version{major: maj, minor: min, patch: patch}} -> {maj, min, patch} >= @floor
      :error -> true
    end
  end

  def supported?(_), do: true
end
