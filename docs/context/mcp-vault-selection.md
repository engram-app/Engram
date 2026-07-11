# Proposal: MCP vault selection + the fate of the "default vault"

_Written 2026-07-10 overnight for Todd's morning review. Covers P0 #985 (MCP set_vault
cosmetic) and the standing question "justify the default vault or kill it." Related: #729,
#951._

## TL;DR

- **Root cause of #985:** MCP over HTTP JSON-RPC is **stateless**. `set_vault` persists
  nothing — its "Active vault: Health" reply is fiction. Every vault-scoped read/write tool
  resolves its vault *per call*, and the only per-call signal (`args["vault_id"]`) was **never
  advertised in any tool schema**, so clients never sent it. With no signal, the server
  **silently fell back to the default vault**. Net: MCP could only ever read the default vault,
  and did so without any error.
- **The default vault is not the villain — silent fallback to it is.** The `is_default` flag has
  exactly one honest job: zero-config routing for single-vault users and onboarding. It has **no
  legitimate role in disambiguating multi-vault access**; using it there is the bug.
- **Shipped fix (this branch, no schema/DB change):** (1) advertise an optional `vault_id` on
  every vault-scoped tool, (2) **fail loud** on multi-vault ambiguity instead of silently
  defaulting, (3) use "your only vault" (not the `is_default` flag) for the single-vault case.
- **Your call (deferred, needs your decision):** whether to keep the `is_default` flag as-is
  (Option 1), derive it and drop the column (Option 2), or move to per-connection binding and
  delete `set_vault` entirely (Option 3). And whether to add tiny per-credential server-side
  state so `set_vault` can become genuinely stateful. I did **not** ship any of these — they're
  architecture calls that are yours.

---

## 1. How vault resolution actually works today

Two auth paths reach `/api/mcp`, both landing in `McpController.resolve_mcp_vault/3`:

| Signal | Where it comes from | Effect today |
|---|---|---|
| `oauth_scope_vault_id` | OAuth JWT `vault_id` claim, chosen at consent | If set → vault is **locked** to it; a different `vault_id` errors ("bound to vault X"). This is #729. |
| `args["vault_id"]` | per-tool-call argument | Honored **if present** — but no read/write tool schema declared it, so it was never present. |
| (nothing) | — | Silent fallback to `conn.assigns.current_vault`, which for MCP is **always the default vault** (VaultPlug gets no `X-Vault-ID` header from MCP clients). |

Key subtlety: the OAuth consent screen **defaults to `vault:*`** (all-vaults, `oauth_scope_vault_id
= nil`). So even the *unbound* token falls through to the silent-default branch. **Every path led
to the default vault.** That's why `set_vault(Health)` echoed correctly (the handler just
validates + echoes) but `list_folders` returned the Engram default tree.

`set_vault` never wrote state anywhere. There is nowhere for it to write — the protocol is one
independent HTTP POST per tool call.

## 2. Why the default vault exists (the justification you asked for)

`vaults.is_default` is a single per-user boolean, set `true` on the first vault created
(`Vaults.create_vault`, `count == 0`). It is consumed in three places:

1. **Onboarding / first sync** — the app needs somewhere to route notes before the user has any
   concept of "vaults." The first vault is default; everything just works.
2. **`VaultPlug` fallback** — a REST request with no `X-Vault-ID` resolves to the default. In
   practice the Obsidian plugin and the SPA both always send the header now (plugin fixed in
   #117), so this is a fallback for un-scoped/legacy/discovery callers.
3. **MCP** — *was* the silent fallback (the #985 bug).

**Honest assessment:** for a single-vault user, "the default vault" and "the user's only vault"
are the same thing — you don't need a stored flag to know which vault to use when there's exactly
one. The flag only does real work when there are **2+ vaults**, and that is precisely the case
where using it as a fallback is wrong: it silently resolves an ambiguous request instead of
making the caller be explicit. So:

> The default vault earns its existence as a **single-vault / onboarding convenience**. It does
> **not** earn a role in multi-vault disambiguation. Every bug in this cluster (#985, and the
> latent half of #951) is the flag being used for the second job.

## 3. What I shipped on this branch (conservative, reversible, no migration)

Scope deliberately limited to things that are unambiguously correct and don't pre-empt your
design decision:

1. **Advertise `vault_id`** (optional, uuid) on every vault-scoped tool schema
   (`search_notes`, `list_tags`, `list_folders`, `list_folder`, `get_note`, `create_folder`,
   `suggest_folder`, and all write tools). Injected in one place in `Tools.list/0` so future
   tools get it automatically; `list_vaults`/`set_vault` are exempt. The mechanism already
   worked end-to-end (the restricted-API-key test proves it) — clients just were never told it
   existed.
2. **Fail loud on ambiguity.** `resolve_mcp_vault/3` no longer silently returns the default:
   - exactly one vault → use it (single-vault users: zero change, zero config);
   - `vault_id` given → resolve + access-check it (unresolvable → clear error, was a silent
     default before);
   - multiple vaults + nothing specified → **error** telling the model to call `list_vaults`
     and pass `vault_id`.
   The default `is_default` flag is no longer consulted on the MCP path at all — "your only
   vault" replaces it, which also sidesteps the deleted-default strand (#951) for single-vault
   users.
3. **`set_vault` told the truth.** Its schema/description now states MCP keeps no active-vault
   state between calls, and its reply echoes the exact `vault_id` to thread on subsequent calls.
   (Handler behavior otherwise unchanged — its real fate is your decision below.)

Regression test added: multi-vault account → `list_folders` with no `vault_id` errors loud;
with `vault_id=B` returns B's tree, not the default. This is the test whose absence let the bug
ship.

**Not shipped (needs your sign-off):** any DB/migration, removal of `is_default`, per-credential
stateful `set_vault`, OAuth consent UX change. See below.

## 4. The decision that's yours

### 4a. Fate of the `is_default` flag

- **Option 1 — keep the flag, fix the fallback semantics (shipped for MCP).** Keep `is_default`
  for onboarding + single-vault convenience; forbid silent multi-vault defaulting everywhere.
  Extend the same fail-loud treatment to `VaultPlug` (REST). Lowest churn. **Recommended.**
- **Option 2 — derive it, drop the column.** "Default" becomes computed: your only vault, else
  none. Requires a migration + touching onboarding, VaultPlug, SPA, and #951's repoint logic.
  Conceptually cleaner; a bigger bet. Worth doing only if the flag keeps causing bugs after
  Option 1.
- **Option 3 — per-connection binding, no runtime switch.** Vault is chosen once at connect time
  (OAuth consent / API-key creation), immutable per credential; multi-vault = multiple
  connectors. Delete `set_vault`. This matches MCP's stateless grain most honestly, and makes
  #729 a non-issue. The cost is UX: to switch vaults in one Claude session you'd reconnect.

### 4b. Should `set_vault` become genuinely stateful?

If you want `set_vault(Health)` to "stick" for the rest of a session without threading `vault_id`
on every call, the server must persist active-vault **per credential** (a tiny
`mcp_active_vault{user_id, credential_key, vault_id}` row or ETS). That's a real (if small)
stateful feature with cross-connection wrinkles (two clients on one token). I did not build it —
it's a genuine product/architecture choice. The shipped per-call `vault_id` makes it optional
rather than required.

### 4c. OAuth consent defaults to `vault:*` silently

Independent of the above: the consent screen picks `vault:*` when no choice is submitted. For a
multi-vault user that's an all-access grant they didn't consciously make, and it feeds the
silent-default path. Recommend making the vault choice explicit in the consent UI (out of scope
for this branch; frontend).

## 5. My recommendation in one line

Ship this branch (Option 1 semantics for MCP), then decide 4a between **Option 1 extended to
VaultPlug** (safe, recommended) and **Option 3** (cleanest, bigger UX change) — and only add
stateful `set_vault` (4b) if you specifically want in-session switching without per-call
`vault_id`.

## References

- `lib/engram_web/controllers/mcp_controller.ex` — `resolve_mcp_vault/3` (the fix site)
- `lib/engram/mcp/tools.ex` — tool schemas (`vault_id` advertising)
- `lib/engram/mcp/handlers.ex` — `set_vault` handler
- `lib/engram_web/plugs/vault_plug.ex` — REST default-vault fallback (Option 1 extension target)
- `lib/engram/oauth.ex` — `resolve_vault/2` (`vault:*` → nil), consent minting
- `docs/context/search-contract-and-vault-id.md` — the plugin-side twin (Bug 2), already fixed
- Issues: #985 (this), #729 (bound-token vs list_vaults), #951 (deleted-default strands clients)
