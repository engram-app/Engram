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

  ## Pre-release tags are ORDERED BELOW their release, and must stay that way

  Plain semver: `1.28.1-pr.512.gabc1234` is BELOW `1.28.1`. That is what
  `Version.compare/2` gives and it is what we want. This was briefly changed to
  compare `{major, minor, patch}` only, on the theory that a preview build is a
  build OF the release it names and should satisfy that release's floor. That
  theory is wrong here, and the change opened a hole.

  `engram-obsidian-sync/scripts/release-version.mjs` derives a preview version
  as `nextPatch(stable) <> "-<tag>"`, where `stable` is read by
  `pr-build.yml` from the **branch's committed `manifest.json`** — which is
  whatever release-please last published, never the branch's own content. So
  EVERY open PR, of any age and any content, is stamped
  `<last-release+1>-pr.<n>.g<sha>`. Two unrelated PRs both claim the same
  triple. A build named `1.28.1-pr.7.gdeadbee` is "stable 1.28.0 plus one
  arbitrary branch", not "a build of 1.28.1".

  `pr-build.yml` then tells the reviewer to install it via BRAT as a **frozen
  version**, which never auto-updates. Ship `@minimum "1.28.1"` later and, if
  the tag were discarded, that reviewer's pre-fix build would report a triple
  equal to the floor and be waved straight through — the exact population this
  gate exists for.

  Ordering pre-releases below their release refuses them instead, which is the
  correct answer: a preview build cannot prove it contains the fix. The cost is
  that a genuine beta of the fixing release is also refused. Accepted — that
  population is small, self-selected, and can install the real release; the
  alternative admits every stale PR build in existence.

  Corollary for whoever raises the floor: do not set it to
  `nextPatch(current_release)` while PR builds carrying that exact triple are
  in the wild. Set it to the version release-please actually published.

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
      # Plain semver ordering, pre-releases included — see the moduledoc for
      # why a `X.Y.Z-pr.N.gSHA` build must NOT satisfy a floor of `X.Y.Z`.
      {:ok, version} -> Version.compare(version, @minimum) != :lt
      :error -> true
    end
  end

  def supported?(_), do: true
end
