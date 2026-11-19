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

  The only things that are ever blocked are a version we successfully parsed
  and found to be strictly below the floor, and (`supported?/2`) no version at
  all from a caller whose user agent names the Obsidian app: that is a plugin
  older than the header, the one population absence-allowed was exempting.

  ## Known false positive: scripts that run inside Obsidian

  The "no version" refusal keys on the Obsidian user agent, which every
  request made from Obsidian's own renderer carries, not just this plugin's.
  A user's Templater/QuickAdd script, or another Obsidian plugin, that calls
  the authed API with an API key and no `X-Plugin-Version` is refused with the
  "update the plugin" 426, and updating cannot help it. The fix on their side
  is to send any parseable `X-Plugin-Version` at or above the floor (the gate
  is self-reported, see above). Accepted: that population is tiny next to the
  stale plugins this closes, and the alternative is leaving them exempt.

  ## Sockets are only partly closed

  The same signal at socket connect sees the WebSocket handshake's user agent.
  On desktop that is the Electron string, so old desktop plugins are refused at
  join. On iOS/Android it is the WebView's string with no `obsidian/` or
  `Dalvik`, so a pre-1.29 mobile socket is NOT refused (its HTTP is, via the
  native request stack). Do not assume sockets are fully closed.

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
    * `EngramWeb.ChannelGate.check/5` (sync + CRDT joins) →
      `plugin_upgrade_required`.

  The socket half is the load-bearing one. Sync runs over CRDT channels, so
  the HTTP plug alone would leave a "blocked" client happily syncing.
  """

  # Raise this in the same PR as the change that makes old clients wrong.
  #
  # 1.36.0 (2026-10-17): Free drops to a 3,000-note cap in the same release.
  # Plugins below 1.36.0 retry every create the cap refuses, one by one, for as
  # long as Obsidian is open, and can trash notes uploaded while a catch-up's
  # manifest is in flight (Engram-obsidian#591). 1.36.0 is the release
  # release-please published with both fixes.
  @minimum "1.36.0"

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

  @doc """
  `supported?/1` plus the one absence we do NOT allow: no version at all from a
  caller whose user agent says it is the Obsidian app.

  Every plugin older than 1.29.0 sends no `X-Plugin-Version`, so under plain
  `supported?/1` it is permanently exempt from every floor, including the one
  whose whole purpose is to stop it (see "What this can and cannot reach"). An
  Obsidian user agent with no version is exactly that population, because the
  1.29.0+ plugin always reports. Everything else that sends no header (web SPA,
  MCP clients, CLI, scripts, self-host) has no Obsidian user agent and stays
  allowed.

  `obsidian?` is `obsidian_client?/1`'s answer. A garbled-but-present version
  still falls through to `supported?/1` (allowed): only absence is the signal.
  Self-reported like the header itself, so a client that wants past it can,
  and this is still a compatibility gate, not a security control.
  """
  @spec supported?(term(), boolean()) :: boolean()
  def supported?(reported, obsidian?) when is_boolean(obsidian?) do
    not (obsidian? and absent?(reported)) and supported?(reported)
  end

  @doc """
  The value to echo as `your_version`: the reported string, or nil for an
  absent or blank one (an empty echo tells the user nothing).
  """
  @spec reported(term()) :: String.t() | nil
  def reported(value) when is_binary(value), do: if(absent?(value), do: nil, else: value)
  def reported(_), do: nil

  @doc """
  The three recovery fields both refusals carry (HTTP 426 body, socket join
  payload). One definition so the transports cannot drift.
  """
  @spec recovery_fields(term()) :: %{
          min_version: String.t(),
          your_version: String.t() | nil,
          update_url: String.t()
        }
  def recovery_fields(reported) do
    %{min_version: @minimum, your_version: reported(reported), update_url: @update_url}
  end

  # The Obsidian app's own HTTP stacks. Desktop is Electron ("obsidian/1.15.1"),
  # iOS is "Obsidian/396 CFNetwork", Android's native HTTP is "Dalvik/" (any
  # Android app; accepted). Measured in prod Tempo 2026-10-31..11-06: every
  # POST /api/notes but a few "node" and "Python-urllib" calls carried one of
  # these. Also the "is this the plugin" signal for `EngramWeb.WriteActor`.
  @obsidian_ua ~r/obsidian\/|^Dalvik\//i

  @doc """
  Whether any of the given user agents (a binary, or the list `get_req_header/2`
  returns) names the Obsidian app. Anything else, including nil, is false.
  """
  @spec obsidian_client?(String.t() | [String.t()] | nil) :: boolean()
  def obsidian_client?(uas) when is_list(uas), do: Enum.any?(uas, &obsidian_client?/1)
  def obsidian_client?(ua) when is_binary(ua), do: Regex.match?(@obsidian_ua, ua)
  def obsidian_client?(_), do: false

  defp absent?(nil), do: true
  defp absent?(value) when is_binary(value), do: String.trim(value) == ""
  defp absent?(_), do: false
end
