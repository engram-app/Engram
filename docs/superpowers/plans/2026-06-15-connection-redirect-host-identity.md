# Connection Identity via Redirect Host — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Identify the claude.ai MCP connector by its redirect host so the connector card shows the Claude mark + "verified" and the onboarding checklist auto-checks "Connect Claude".

**Architecture:** `LogoAllowlist` gains a redirect-host map and a `resolve/2` that tries `software_id` first, then host. `Connections.oauth_rows/1` calls `resolve/2` and adds `slug` to the connection view; the controller serializes `slug`. The React checklist marks a tool row done when a live MCP connection carries that slug. Card needs no change.

**Tech Stack:** Elixir/Phoenix (ExUnit, ExMachina factory), React/TS (Vitest), single engram repo PR.

---

### Task 1: Redirect-host resolution in LogoAllowlist

**Files:**
- Modify: `lib/engram/connections/logo_allowlist.ex`
- Test: `test/engram/connections/logo_allowlist_test.exs`

- [ ] **Step 1: Add failing tests**

Append to `logo_allowlist_test.exs` (inside the module):

```elixir
  test "resolve matches verified Claude by claude.ai redirect host" do
    result = LogoAllowlist.resolve(nil, ["https://claude.ai/api/mcp/auth_callback"])
    assert %{verified: true, slug: "claude", display_name: "Claude",
             logo: "/assets/clients/claude.svg"} = result
  end

  test "resolve prefers software_id over redirect host" do
    result = LogoAllowlist.resolve("engram-vault-sync", ["https://claude.ai/x"])
    assert %{verified: true, slug: nil, logo: "/assets/clients/engram-vault-sync.svg"} = result
  end

  test "resolve ignores loopback and custom-scheme redirects" do
    assert %{verified: false, logo: nil, slug: nil} =
             LogoAllowlist.resolve(nil, ["http://127.0.0.1:51234/cb"])
    assert %{verified: false, slug: nil} = LogoAllowlist.resolve(nil, ["cursor://anysescheme"])
  end

  test "resolve handles nil/empty redirect list" do
    assert %{verified: false, slug: nil} = LogoAllowlist.resolve(nil, nil)
    assert %{verified: false, slug: nil} = LogoAllowlist.resolve(nil, [])
  end

  test "lookup result carries slug key" do
    assert %{slug: nil} = LogoAllowlist.lookup("engram-vault-sync")
  end
```

- [ ] **Step 2: Run, expect fail**

Run: `mix test test/engram/connections/logo_allowlist_test.exs`
Expected: FAIL — `resolve/2` undefined; `:slug` missing.

- [ ] **Step 3: Implement**

Replace the body of `lib/engram/connections/logo_allowlist.ex` with:

```elixir
defmodule Engram.Connections.LogoAllowlist do
  @moduledoc """
  Identity metadata for OAuth clients. Primary key is the RFC 7591
  `software_id`, but most MCP clients omit it — so `resolve/2` falls back to
  matching the `redirect_uri` host against a map of vendor-owned HTTPS hosts.

  A vendor HTTPS host is un-spoofable for grant delivery (the auth code lands
  at the vendor, not a forger), so a host match grants `verified: true`. Custom
  schemes (`cursor://`) and loopback never match the host map.

  Unknown ids/hosts return an unverified placeholder so the UI can render an
  "Unverified client" badge.
  """

  @empty %{verified: false, logo: nil, display_name: nil, slug: nil}

  # Keyed on RFC 7591 software_id. `engram-vault-sync` is our own plugin and is
  # the only proven-real entry. The other four are unvalidated guesses left in
  # place (harmless — real clients never send them) pending observation.
  @software_id %{
    "engram-vault-sync" => %{
      logo: "/assets/clients/engram-vault-sync.svg",
      display_name: "Obsidian Vault Sync",
      slug: nil
    },
    "anthropic-claude-desktop" => %{
      logo: "/assets/clients/claude.svg",
      display_name: "Claude Desktop",
      slug: "claude"
    },
    "cursor.sh" => %{logo: "/assets/clients/cursor.svg", display_name: "Cursor", slug: "cursor"},
    "openai-chatgpt" => %{logo: "/assets/clients/chatgpt.svg", display_name: "ChatGPT", slug: "chatgpt"},
    "vscode-engram" => %{logo: "/assets/clients/vscode.svg", display_name: "VS Code (Engram)", slug: nil}
  }

  # Keyed on redirect_uri host. Vendor-owned HTTPS hosts only.
  @redirect_host %{
    "claude.ai" => %{
      logo: "/assets/clients/claude.svg",
      display_name: "Claude",
      slug: "claude"
    }
  }

  @type entry :: %{
          verified: boolean(),
          logo: String.t() | nil,
          display_name: String.t() | nil,
          slug: String.t() | nil
        }

  @doc "Resolve identity from software_id first, then redirect host."
  @spec resolve(String.t() | nil, [String.t()] | nil) :: entry()
  def resolve(software_id, redirect_uris) do
    case lookup(software_id) do
      %{verified: true} = hit -> hit
      _ -> lookup_by_host(redirect_uris)
    end
  end

  @spec lookup(String.t() | nil) :: entry()
  def lookup(software_id) when is_binary(software_id) do
    case Map.get(@software_id, software_id) do
      nil -> @empty
      entry -> Map.merge(%{verified: true}, entry)
    end
  end

  def lookup(_), do: @empty

  defp lookup_by_host(uris) when is_list(uris) do
    Enum.find_value(uris, @empty, fn uri ->
      host = URI.parse(uri).host

      case host && Map.get(@redirect_host, host) do
        nil -> nil
        entry -> Map.merge(%{verified: true}, entry)
      end
    end)
  end

  defp lookup_by_host(_), do: @empty
end
```

- [ ] **Step 4: Run, expect pass**

Run: `mix test test/engram/connections/logo_allowlist_test.exs`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/connections/logo_allowlist.ex test/engram/connections/logo_allowlist_test.exs
git commit -m "feat(connections): resolve client identity by redirect host"
```

---

### Task 2: Thread slug through Connections views

**Files:**
- Modify: `lib/engram/connections.ex` (typespec ~159-168; `oauth_rows/1` ~198-216; `pat_rows/1` map; `device_rows/1` map)
- Test: `test/engram/connections_test.exs`

- [ ] **Step 1: Add failing test**

Append inside the `describe "list_for_user/1"` block:

```elixir
    test "identifies claude.ai connector by redirect host" do
      user = insert_user()

      client =
        insert(:oauth_client,
          kind: "mcp",
          software_id: nil,
          client_name: "Claude",
          redirect_uris: ["https://claude.ai/api/mcp/auth_callback"]
        )

      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id)

      assert [%{kind: :mcp, name: "Claude", verified: true, slug: "claude",
                logo: "/assets/clients/claude.svg"}] = Connections.list_for_user(user)
    end
```

- [ ] **Step 2: Run, expect fail**

Run: `mix test test/engram/connections_test.exs -m "identifies claude.ai"` (or run the file)
Expected: FAIL — `:slug` key absent / `verified` false.

- [ ] **Step 3: Implement**

In `lib/engram/connections.ex` `oauth_rows/1`, replace the lookup + map:

```elixir
    |> Enum.map(fn {t, c} ->
      identity = LogoAllowlist.resolve(c.software_id, c.redirect_uris)

      %{
        kind: String.to_existing_atom(c.kind),
        client_id: c.client_id,
        key_id: nil,
        name: identity.display_name || c.client_name,
        software_id: c.software_id,
        software_version: c.software_version,
        verified: identity.verified,
        logo: identity.logo,
        slug: identity.slug,
        vault_id: t.vault_id,
        scope: t.scope,
        last_used_at: t.last_used_at,
        connected_at: t.inserted_at,
        first_user_agent: c.first_user_agent,
        first_ip: format_inet(c.first_ip),
        redirect_uris: c.redirect_uris || []
      }
    end)
```

Add `slug: nil,` to the map built in `pat_rows/1` (next to `logo: nil,`) and to the map in `device_rows/1`. In the `connection_view` typespec block add `slug: String.t() | nil,`.

- [ ] **Step 4: Run, expect pass**

Run: `mix test test/engram/connections_test.exs`
Expected: PASS (existing + new).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/connections.ex test/engram/connections_test.exs
git commit -m "feat(connections): add slug to connection view"
```

---

### Task 3: Serialize slug in the API

**Files:**
- Modify: `lib/engram_web/controllers/connections_controller.ex` (`serialize/1` ~96-115)
- Test: `test/engram_web/controllers/connections_controller_test.exs`

- [ ] **Step 1: Add failing assertion**

In the test that asserts the Claude/MCP row (around line 50-55), add:

```elixir
      assert mcp["slug"] == "claude"
```

Ensure that test's inserted client carries `software_id: "anthropic-claude-desktop"` (already does → slug "claude"), OR if it relies on redirect host, set `redirect_uris: ["https://claude.ai/api/mcp/auth_callback"]`. Use the existing software_id path already present at line ~35.

- [ ] **Step 2: Run, expect fail**

Run: `mix test test/engram_web/controllers/connections_controller_test.exs`
Expected: FAIL — `mcp["slug"]` is nil (key absent).

- [ ] **Step 3: Implement**

In `serialize/1` add `slug: row.slug,` next to `logo: row.logo,`.

- [ ] **Step 4: Run, expect pass**

Run: `mix test test/engram_web/controllers/connections_controller_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/controllers/connections_controller.ex test/engram_web/controllers/connections_controller_test.exs
git commit -m "feat(connections): expose slug in /connections payload"
```

---

### Task 4: Checklist auto-checks connected tools

**Files:**
- Modify: `frontend/src/api/queries.ts` (`Connection` interface ~773-790)
- Modify: `frontend/src/onboarding/checklist-widget.tsx` (~69, ~103-144)
- Test: `frontend/src/onboarding/checklist-widget.test.tsx`

- [ ] **Step 1: Add failing test**

Add inside `describe('ChecklistWidget — per-tool rows', ...)`:

```tsx
  it('auto-clears a tool row when a matching MCP connection exists', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: ['claude', 'cursor'] }
    connectionsValue = {
      data: [{ kind: 'mcp', slug: 'claude', client_id: 'c1', key_id: null, name: 'Claude',
        software_id: null, software_version: null, verified: true,
        logo: '/assets/clients/claude.svg', vault_id: null, vault_name: null, scope: 'mcp',
        last_used_at: null, connected_at: null, first_user_agent: null, first_ip: null,
        redirect_uris: ['https://claude.ai/api/mcp/auth_callback'] }],
      isLoading: false,
    }
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    expect(screen.queryByText(/connect claude/i)).not.toBeInTheDocument()
    expect(screen.getByText(/connect cursor/i)).toBeInTheDocument()
  })
```

- [ ] **Step 2: Run, expect fail**

Run: `cd frontend && bun run test checklist-widget` (or `bunx vitest run src/onboarding/checklist-widget.test.tsx`)
Expected: FAIL — "Connect Claude" still rendered.

- [ ] **Step 3: Implement**

In `frontend/src/api/queries.ts` add to the `Connection` interface (after `logo`):

```ts
  slug: string | null
```

In `frontend/src/onboarding/checklist-widget.tsx`:

Un-gate connections (line ~69):

```tsx
  const connections = useConnections()
```

After `const tools = ...` (line ~103) add:

```tsx
  const connectedSlugs = new Set(
    (connections.data ?? [])
      .filter((c) => c.kind === 'mcp')
      .map((c) => c.slug)
      .filter((s): s is string => !!s),
  )
```

Change the per-tool row `done` (line ~138):

```tsx
        done: isDismissed(slug) || connectedSlugs.has(slug),
```

- [ ] **Step 4: Run, expect pass**

Run: `cd frontend && bunx vitest run src/onboarding/checklist-widget.test.tsx`
Expected: PASS (existing + new).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/api/queries.ts frontend/src/onboarding/checklist-widget.tsx frontend/src/onboarding/checklist-widget.test.tsx
git commit -m "feat(onboarding): auto-check checklist row when tool connected"
```

---

### Task 5: Full verification

- [ ] **Step 1: Backend tests**

Run: `mix test test/engram/connections_test.exs test/engram/connections/logo_allowlist_test.exs test/engram_web/controllers/connections_controller_test.exs`
Expected: all PASS.

- [ ] **Step 2: Frontend tests + typecheck + lint**

Run: `cd frontend && bunx vitest run src/onboarding/ src/settings/ && bun run build`
Expected: tests PASS, tsc + build clean.

- [ ] **Step 3: Browser proof**

Reload `https://app.engram.page/settings/connections` (once deployed / against local saas-dev): Claude card shows the Claude mark, "unverified" gone, name "Claude"; the "Connect Claude" checklist row is absent.

---

## Self-Review

- **Spec coverage:** redirect-host matcher (T1) ✓; `engram-vault-sync` preserved (T1 test) ✓; slug in view (T2) + payload (T3) ✓; card unchanged (no task needed) ✓; checklist un-gate + auto-check, no icons (T4) ✓; trust model = HTTPS host only, loopback/scheme excluded (T1 test) ✓; tests per the spec's Testing section ✓.
- **Placeholders:** none — every step has concrete code/commands.
- **Type consistency:** `resolve/2`, `lookup/1`, `entry` map shape `{verified, logo, display_name, slug}` consistent across T1–T3; `Connection.slug` (T4) matches serialized `slug` (T3); checklist reads `c.slug` (T4) matching the same field.
- **Note:** guessed `software_id` entries gain a `slug` (claude/cursor/chatgpt) so they still resolve correctly if ever hit — harmless, keeps T1 `resolve prefers software_id` semantics intact.
