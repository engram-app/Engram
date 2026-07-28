# Vault-Scoped SPA URLs + Settings Hash Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the SPA URL describe what the user is looking at: vault-scoped note paths (`/:slug/:noteId`) with the URL as the source of truth for the active vault, and settings addressed by hash (`#settings/<section>`) so it overlays the current page instead of replacing it.

**Architecture:** `useActiveVaultId()` has 30+ consumers that stay untouched; only the *writer* changes, from `localStorage` to a new `VaultRoute` component that resolves the URL slug. Settings stays the Radix `Dialog` it already is, but moves from a path route to a hash-driven overlay mounted above the app shell so it works on `/link` and `/oauth/consent` too. Phoenix gets an explicit deny-list so the new dynamic SPA routes cannot swallow typo'd API paths.

**Tech Stack:** React 19, React Router 7, TanStack Query 5, Radix UI, Vitest + Testing Library (frontend); Elixir 1.17 / Phoenix 1.8, ExUnit (backend); pytest + Playwright (E2E).

**Spec:** Engram vault, `50 Engineering/_Superpowers Specs/2026-07-28-frontend-vault-scoped-urls-design.md`

## Global Constraints

- Repo: `engram-app/engram`. Work in a git worktree (`~/documents/code-projects/engram/.worktrees/<branch>`), never the shared `backend/` symlink checkout. Copy `.env.local-selfhost` into the worktree before any `make saas-dev` run; it is gitignored so `git worktree add` will not bring it.
- Branch: `feat/vault-scoped-urls`. Conventional commits, subject under 50 chars.
- ONE PR for the whole plan. Do not open intermediate PRs.
- Do NOT bump `mix.exs` version in feature commits; the release flow owns it.
- Frontend lint/format: `./node_modules/.bin/biome ci` (never `bunx biome`, wrong version). Run `bun run lint:css` and `bun run lint:obsidian` if present.
- Backend before push: `mix format`, `mix credo`, `mix dialyzer`, and the FULL `mix test`.
- The vault segment is `Vault.slug` (plaintext, per-user unique). Never `Vault.name` (encrypted, virtual).
- Unknown vault slug renders the existing `NotFoundPage`. Never silently redirect to the default vault.
- No `!important` in CSS. No em dashes in user-facing copy.
- `@testing-library/user-event` is NOT a dependency. Use `fireEvent` from `@testing-library/react`, the existing convention across the suite. Add it to the file's existing `@testing-library/react` import where a snippet below uses it.
- Nav links inside the settings dialog must be react-router `<Link>`, never a plain `<a href="#...">`. React Router v8's browser history listens to `popstate` only (`node_modules/react-router/dist/development/lib/router/history.js:335`); a native anchor hash navigation fires `hashchange` but not `popstate`, so `useLocation()` would go stale and `SettingsOverlayHost` would stop switching sections. `<Link to="#settings/x">` resolves to `<pathname>#settings/x`, so assert href with a suffix match, never string equality against a bare hash.
- Reserved slug list, verbatim, identical in Elixir and TypeScript:
  `sign-in sign-up waitlist link oauth onboard reset-password note search billing settings api webhooks .well-known`

---

## File Structure

**Create (frontend, `backend/frontend/src/`):**

| Path | Responsibility |
|---|---|
| `settings/settings-hash.ts` | Parse and build `#settings/<section>`. Pure, no React. |
| `settings/settings-overlay-host.tsx` | Renders `<Outlet/>` plus the settings dialog when the hash matches. |
| `settings/legacy-settings-redirect.tsx` | `/settings/*` to `/#settings/<section>`. |
| `api/vault-slug.ts` | `vaultBySlug`, `preferredVault` (pure, Task 9) plus the `useActiveVaultSlug` hook (Task 12). |
| `api/reserved-slugs.ts` | TS mirror of the Elixir reserved list. |
| `viewer/vault-route.tsx` | Resolves `:slug`, writes the active-vault store, holds children until it agrees. |
| `viewer/vault-redirect.tsx` | Bare `/` to `/<slug>`. |
| `viewer/legacy-note-redirect.tsx` | `/note/:id` to `/<slug>/:id`. |

**Modify (frontend):** `settings/settings-layout.tsx` (dialog takes a `section` prop, renders the section body directly, close strips the hash), `settings/sections.ts` (add the `key` field), `router.tsx`, `layout/vault-switcher.tsx`, `layout/rail.tsx`, `layout/user-menu.tsx`, `layout/app-sidebar.tsx`, `layout/empty-vault-state.tsx`, `layout/search-panel.tsx`, `billing/upgrade-required-dialog.tsx`, `device/device-link-page.tsx`, `oauth/oauth-authorize-page.tsx`, `settings/connections-page.tsx`, `settings/vaults/active-vaults-section.tsx`, `settings/account/connected-accounts-section.tsx`, `api/queries.ts`, `viewer/dashboard.tsx`, `viewer/tree/tree-row.tsx`, `onboarding/onboarding-shell.tsx`, `onboarding/tour/controller.tsx`.

**Modify (backend):** `lib/engram_web/router.ex`, `lib/engram_web/controllers/spa_controller.ex`, `lib/engram/vaults/vault.ex`, `lib/engram_web/plugs/enforce_pat_creation.ex`, `lib/engram_web/plugs/require_api_write_enabled.ex`, `lib/engram_web/plugs/enforce_connection_cap.ex`, `lib/engram/workers/vault_deleted_email.ex`, `e2e/helpers/web_spa.py`, `e2e/tests/api_only/test_71_connections.py`.

---

## Task 1: Settings hash parsing

**Files:**
- Create: `backend/frontend/src/settings/settings-hash.ts`
- Modify: `backend/frontend/src/settings/sections.ts`
- Test: `backend/frontend/src/settings/settings-hash.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `type SettingsSectionKey = "account" | "vaults" | "connections" | "billing" | "admin"`; `isSettingsHash(hash: string): boolean`; `parseSettingsHash(hash: string): SettingsSectionKey | null`; `settingsHash(section: SettingsSectionKey): string`. `sections.ts` gains `SettingsSection.key: SettingsSectionKey` alongside the existing `to` and `label`.

- [ ] **Step 1: Write the failing test**

Create `backend/frontend/src/settings/settings-hash.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { isSettingsHash, parseSettingsHash, settingsHash } from "./settings-hash";

describe("isSettingsHash", () => {
	it("matches the bare prefix and sectioned forms", () => {
		expect(isSettingsHash("#settings")).toBe(true);
		expect(isSettingsHash("#settings/billing")).toBe(true);
	});

	it("rejects empty, unrelated, and prefix-lookalike hashes", () => {
		expect(isSettingsHash("")).toBe(false);
		expect(isSettingsHash("#tour")).toBe(false);
		expect(isSettingsHash("#settingsfoo")).toBe(false);
	});
});

describe("parseSettingsHash", () => {
	it("returns null for a non-settings hash", () => {
		expect(parseSettingsHash("")).toBeNull();
		expect(parseSettingsHash("#tour")).toBeNull();
	});

	it("defaults a bare prefix to account", () => {
		expect(parseSettingsHash("#settings")).toBe("account");
		expect(parseSettingsHash("#settings/")).toBe("account");
	});

	it("returns each known section", () => {
		expect(parseSettingsHash("#settings/account")).toBe("account");
		expect(parseSettingsHash("#settings/vaults")).toBe("vaults");
		expect(parseSettingsHash("#settings/connections")).toBe("connections");
		expect(parseSettingsHash("#settings/billing")).toBe("billing");
		expect(parseSettingsHash("#settings/admin")).toBe("admin");
	});

	it("maps the legacy api-keys alias to connections", () => {
		expect(parseSettingsHash("#settings/api-keys")).toBe("connections");
	});

	it("falls back to account for an unknown section", () => {
		expect(parseSettingsHash("#settings/garbage")).toBe("account");
	});
});

describe("settingsHash", () => {
	it("round-trips through parseSettingsHash", () => {
		expect(settingsHash("billing")).toBe("#settings/billing");
		expect(parseSettingsHash(settingsHash("vaults"))).toBe("vaults");
	});
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend/frontend && bun run test -- settings-hash`
Expected: FAIL, "Failed to resolve import ./settings-hash".

- [ ] **Step 3: Write minimal implementation**

Create `backend/frontend/src/settings/settings-hash.ts`:

```ts
// Settings is addressed by hash, not path, so the dialog overlays whatever page
// you were on and closing can simply strip the hash instead of inventing a
// destination (the old `/settings/*` path route hardcoded `navigate("/")`,
// which dumped you on the dashboard even if you came from a note).
const PREFIX = "#settings";

export type SettingsSectionKey = "account" | "vaults" | "connections" | "billing" | "admin";

const KNOWN: readonly string[] = ["account", "vaults", "connections", "billing", "admin"];

// Carried over from the old `/settings/api-keys` route alias so existing links
// and bookmarks keep landing on Connections.
const ALIASES: Record<string, SettingsSectionKey> = { "api-keys": "connections" };

export function isSettingsHash(hash: string): boolean {
	return hash === PREFIX || hash.startsWith(`${PREFIX}/`);
}

export function parseSettingsHash(hash: string): SettingsSectionKey | null {
	if (!isSettingsHash(hash)) {
		return null;
	}
	const raw = hash.slice(PREFIX.length).replace(/^\//, "");
	if (raw === "") {
		return "account";
	}
	const resolved = ALIASES[raw] ?? raw;
	// An unknown section is a typo or a stale link, not a reason to render
	// nothing: open on Account rather than an empty dialog body.
	return KNOWN.includes(resolved) ? (resolved as SettingsSectionKey) : "account";
}

export function settingsHash(section: SettingsSectionKey): string {
	return `${PREFIX}/${section}`;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend/frontend && bun run test -- settings-hash`
Expected: PASS, 8 tests.

- [ ] **Step 5: Add the `key` field to sections**

Replace `backend/frontend/src/settings/sections.ts` entirely:

```ts
import type { EngramConfig } from "../config";
import type { SettingsSectionKey } from "./settings-hash";

export interface SettingsSection {
	key: SettingsSectionKey;
	label: string;
}

export function buildSettingsSections(
	authProvider: EngramConfig["authProvider"],
	billingEnabled: boolean,
	isAdmin = false,
): SettingsSection[] {
	const sections: SettingsSection[] = [
		{ key: "account", label: "Account" },
		{ key: "vaults", label: "Vaults" },
		{ key: "connections", label: "Connections" },
	];

	if (billingEnabled) {
		sections.push({ key: "billing", label: "Billing" });
	}

	if (authProvider === "local" && isAdmin) {
		sections.push({ key: "admin", label: "Administration" });
	}

	return sections;
}
```

- [ ] **Step 6: Fix the existing sections test**

Run: `cd backend/frontend && bun run test -- sections`
If `sections.test.ts` exists and asserts on `to`, change each `to:` assertion to `key:`. The values are identical strings, so only the property name changes.

- [ ] **Step 7: Commit**

```bash
git add src/settings/settings-hash.ts src/settings/settings-hash.test.ts src/settings/sections.ts
git commit -m "feat(settings): add hash addressing helpers"
```

---

## Task 2: Settings dialog renders a section by prop

**Files:**
- Modify: `backend/frontend/src/settings/settings-layout.tsx`
- Test: `backend/frontend/src/settings/settings-layout.test.tsx`

**Interfaces:**
- Consumes: `SettingsSectionKey`, `settingsHash`, `parseSettingsHash` from Task 1; `buildSettingsSections` with the new `key` field.
- Produces: `settings-layout.tsx` default-exports `SettingsDialog({ section }: { section: SettingsSectionKey })`. It no longer renders `<Outlet/>` and no longer requires child routes.

The dialog currently gets its body from React Router's `<Outlet/>` (child routes in `router.tsx`). With settings off the path, there are no child routes, so the dialog maps the section to a component itself.

- [ ] **Step 1: Write the failing test**

Replace the body of `backend/frontend/src/settings/settings-layout.test.tsx`'s `renderAt` helper and add these cases. Keep the existing `vi.mock` and `testConfig` at the top of the file:

```tsx
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import { fireEvent } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router";
import { describe, expect, it } from "vitest";
// NOTE: `@testing-library/user-event` is NOT a dependency of this repo. Use
// `fireEvent`, which is the existing convention across the frontend suite.
import { ConfigProvider } from "../config-context";
import { ThemeProvider } from "../theme/theme-provider";
import SettingsDialog from "./settings-layout";
import type { SettingsSectionKey } from "./settings-hash";

function LocationProbe() {
	const loc = useLocation();
	return <output data-testid="loc">{`${loc.pathname}${loc.hash}`}</output>;
}

function renderDialog(section: SettingsSectionKey, initialEntry = "/work/note-1#settings/account") {
	const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(
		<ConfigProvider config={testConfig}>
			<QueryClientProvider client={client}>
				<ThemeProvider>
					<MemoryRouter initialEntries={[initialEntry]}>
						<LocationProbe />
						<SettingsDialog section={section} />
					</MemoryRouter>
				</ThemeProvider>
			</QueryClientProvider>
		</ConfigProvider>,
	);
}

describe("SettingsDialog", () => {
	it("renders the nav with a link per section", async () => {
		renderDialog("account");
		// `<Link to="#settings/billing">` resolves against the current location, so
		// the href is `/work/note-1#settings/billing`, not a bare hash. Assert the
		// suffix: the requirement is "targets billing from wherever you are".
		const link = await screen.findByRole("link", { name: "Billing" });
		expect(link.getAttribute("href")).toMatch(/#settings\/billing$/);
	});

	it("switches section on click without leaving the page", () => {
		renderDialog("account", "/work/note-1#settings/account");
		fireEvent.click(screen.getByRole("link", { name: "Billing" }));
		// Guards against dropping out of the router to a plain <a>: react-router v8
		// listens to popstate ONLY (no hashchange listener), so a native anchor hash
		// nav would update window.location.hash while useLocation() stayed stale,
		// and SettingsOverlayHost (Task 3) reads useLocation().hash.
		expect(screen.getByTestId("loc")).toHaveTextContent("/work/note-1#settings/billing");
	});

	it("marks the current section as the active nav item", async () => {
		renderDialog("vaults");
		expect(await screen.findByRole("link", { name: "Vaults" })).toHaveAttribute(
			"aria-current",
			"page",
		);
		expect(screen.getByRole("link", { name: "Account" })).not.toHaveAttribute("aria-current");
	});

	it("strips the hash on close and keeps you on the same page", async () => {
		// The close navigate is deferred by CLOSE_ANIMATION_MS so the Radix exit
		// transition plays. Advance the clock explicitly rather than waiting on
		// it: with real timers this asserts a deterministic behavior by racing
		// the wall clock, and under full-suite parallel load the event loop
		// starves past findBy*'s 1000ms default. Measured ~17% flake rate that
		// way. Fake timers remove the race instead of widening the window.
		vi.useFakeTimers();
		try {
			renderDialog("account", "/work/note-1#settings/account");
			fireEvent.click(screen.getByRole("button", { name: /close settings/i }));
			await act(async () => {
				vi.advanceTimersByTime(CLOSE_ANIMATION_MS);
			});
			expect(screen.getByText("/work/note-1")).toBeInTheDocument();
		} finally {
			vi.useRealTimers();
		}
	});

	it("falls back to account when the section is unavailable in this config", async () => {
		const localConfig = { ...testConfig, authProvider: "local" as const, billingEnabled: false };
		const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
		render(
			<ConfigProvider config={localConfig}>
				<QueryClientProvider client={client}>
					<ThemeProvider>
						<MemoryRouter initialEntries={["/work#settings/billing"]}>
							<SettingsDialog section="billing" />
						</MemoryRouter>
					</ThemeProvider>
				</QueryClientProvider>
			</ConfigProvider>,
		);
		// Billing is not a section on a self-host build, so the nav must not
		// offer it and the body must not be the billing page.
		expect(screen.queryByRole("link", { name: "Billing" })).toBeNull();
	});
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend/frontend && bun run test -- settings-layout`
Expected: FAIL. `SettingsDialog` does not accept a `section` prop and the nav still emits `href="/settings/billing"`.

- [ ] **Step 3: Rework the component**

In `backend/frontend/src/settings/settings-layout.tsx`:

Add these imports at the top, next to the existing ones:

```tsx
import { lazy, Suspense, useEffect, useState } from "react";
import { Link, useLocation, useNavigate } from "react-router";
import { type SettingsSectionKey, settingsHash } from "./settings-hash";
```

Remove `NavLink` and `Outlet` from the `react-router` import.

Add the lazy section bodies at module scope, below the imports. These are the exact modules `router.tsx` lazy-loads today:

```tsx
const AccountPage = lazy(() => import("./account-page"));
const AccountPageLocal = lazy(() => import("./account-page-local"));
const VaultsPage = lazy(() => import("./vaults-page"));
const ConnectionsPage = lazy(() => import("./connections-page"));
const BillingPage = lazy(() => import("../billing/billing-page"));
const AdminPanel = lazy(() => import("../features/admin/AdminPanel"));

function SectionBody({ section }: { section: SettingsSectionKey }) {
	const config = useConfig();
	switch (section) {
		case "vaults":
			return <VaultsPage />;
		case "connections":
			return <ConnectionsPage />;
		case "billing":
			return <BillingPage />;
		case "admin":
			return <AdminPanel />;
		default:
			return config.authProvider === "clerk" ? <AccountPage /> : <AccountPageLocal />;
	}
}
```

Replace `SettingsNavList` so it links by hash and computes its own active state. `NavLink`'s `isActive` compares pathname only, which is always the underlying page here, so it can never match:

```tsx
function SettingsNavList({
	sections,
	current,
	onNavigate,
}: {
	sections: SettingsSection[];
	current: SettingsSectionKey;
	onNavigate?: () => void;
}) {
	return (
		<ul className="space-y-1">
			{sections.map((s) => {
				const active = s.key === current;
				return (
					<li key={s.key}>
						<Link
							to={settingsHash(s.key)}
							onClick={onNavigate}
							aria-current={active ? "page" : undefined}
							className={`block rounded-md px-3 py-2 text-sm transition-colors ${
								active
									? "bg-primary/10 font-medium text-primary"
									: "text-muted-foreground hover:bg-accent hover:text-accent-foreground"
							}`}
						>
							{s.label}
						</Link>
					</li>
				);
			})}
		</ul>
	);
}
```

Change the component signature and the close effect. Everything between `<Dialog>` and `</Dialog>` stays byte-identical except the two `SettingsNavList` call sites (which gain `current={current}`) and the `<Outlet />` at line 135:

```tsx
export default function SettingsDialog({ section }: { section: SettingsSectionKey }) {
	const config = useConfig();
	const { data: me } = useMe();
	const isAdmin = me?.role === "admin";
	const sections = buildSettingsSections(config.authProvider, config.billingEnabled, isAdmin);
	const [navOpen, setNavOpen] = useState(false);
	const [open, setOpen] = useState(true);
	const navigate = useNavigate();
	const location = useLocation();

	// A hash can name a section this build does not have (`#settings/billing` on
	// self-host, `#settings/admin` as a non-admin). Fall back rather than render
	// an empty dialog body.
	const current = sections.some((s) => s.key === section) ? section : "account";

	// Close = strip the hash. Deferred by CLOSE_ANIMATION_MS so the Radix exit
	// transition plays. This replaces the old `navigate("/")`, which threw away
	// whatever page the user opened settings from.
	useEffect(() => {
		if (open) {
			return;
		}
		const t = setTimeout(
			() => navigate({ pathname: location.pathname, search: location.search, hash: "" }),
			CLOSE_ANIMATION_MS,
		);
		return () => clearTimeout(t);
	}, [open, navigate, location.pathname, location.search]);
```

Replace `<Outlet />` (line 135) with:

```tsx
<Suspense fallback={<p className="text-muted-foreground">Loading…</p>}>
	<SectionBody section={current} />
</Suspense>
```

Update both `<SettingsNavList sections={sections} .../>` call sites to pass `current={current}`.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend/frontend && bun run test -- settings-layout`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/settings/settings-layout.tsx src/settings/settings-layout.test.tsx
git commit -m "feat(settings): render section by prop, close strips hash"
```

---

## Task 3: Settings overlay host and legacy redirect

**Files:**
- Create: `backend/frontend/src/settings/settings-overlay-host.tsx`
- Create: `backend/frontend/src/settings/legacy-settings-redirect.tsx`
- Test: `backend/frontend/src/settings/settings-overlay-host.test.tsx`

**Interfaces:**
- Consumes: `parseSettingsHash`, `settingsHash` (Task 1); `SettingsDialog` (Task 2).
- Produces: `SettingsOverlayHost` (default export, renders `<Outlet/>` plus the dialog); `LegacySettingsRedirect` (default export).

- [ ] **Step 1: Write the failing test**

Create `backend/frontend/src/settings/settings-overlay-host.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router";
import { describe, expect, it, vi } from "vitest";
import LegacySettingsRedirect from "./legacy-settings-redirect";
import SettingsOverlayHost from "./settings-overlay-host";

// The dialog pulls the whole settings surface (Clerk hooks, billing, admin);
// stub it so this file tests only the host's mount decision.
vi.mock("./settings-layout", () => ({
	default: ({ section }: { section: string }) => <p data-testid="dialog">section:{section}</p>,
}));

function LocationProbe() {
	const loc = useLocation();
	return <output data-testid="loc">{`${loc.pathname}${loc.search}${loc.hash}`}</output>;
}

function renderHost(entry: string) {
	return render(
		<MemoryRouter initialEntries={[entry]}>
			<Routes>
				<Route element={<SettingsOverlayHost />}>
					<Route path="/work/:id" element={<p>note body</p>} />
				</Route>
			</Routes>
		</MemoryRouter>,
	);
}

describe("SettingsOverlayHost", () => {
	it("renders the page alone when there is no settings hash", () => {
		renderHost("/work/note-1");
		expect(screen.getByText("note body")).toBeInTheDocument();
		expect(screen.queryByTestId("dialog")).toBeNull();
	});

	it("keeps the page mounted underneath when settings is open", async () => {
		renderHost("/work/note-1#settings/billing");
		// The page underneath is synchronous (plain Outlet), but the dialog is
		// lazy(), so it sits behind a Suspense boundary that resolves on a
		// microtask. `vi.mock` does not make the dynamic import synchronous.
		// Await the dialog; asserting it with a sync getBy* would always throw.
		expect(screen.getByText("note body")).toBeInTheDocument();
		expect(await screen.findByTestId("dialog")).toHaveTextContent("section:billing");
	});

	it("ignores unrelated hashes", () => {
		renderHost("/work/note-1#tour");
		expect(screen.queryByTestId("dialog")).toBeNull();
	});
});

describe("LegacySettingsRedirect", () => {
	function renderRedirect(entry: string) {
		return render(
			<MemoryRouter initialEntries={[entry]}>
				<LocationProbe />
				<Routes>
					<Route path="/settings" element={<LegacySettingsRedirect />} />
					<Route path="/settings/*" element={<LegacySettingsRedirect />} />
					<Route path="/" element={<p>root</p>} />
				</Routes>
			</MemoryRouter>,
		);
	}

	it("maps a bare /settings to the account hash", () => {
		renderRedirect("/settings");
		expect(screen.getByTestId("loc")).toHaveTextContent("/#settings/account");
	});

	it("maps a section path to its hash", () => {
		renderRedirect("/settings/billing");
		expect(screen.getByTestId("loc")).toHaveTextContent("/#settings/billing");
	});

	it("maps the legacy api-keys path to connections", () => {
		renderRedirect("/settings/api-keys");
		expect(screen.getByTestId("loc")).toHaveTextContent("/#settings/connections");
	});

	it("preserves the query string", () => {
		renderRedirect("/settings/vaults?highlight=abc");
		expect(screen.getByTestId("loc")).toHaveTextContent("/?highlight=abc#settings/vaults");
	});
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend/frontend && bun run test -- settings-overlay-host`
Expected: FAIL, "Failed to resolve import ./settings-overlay-host".

- [ ] **Step 3: Write the host**

Create `backend/frontend/src/settings/settings-overlay-host.tsx`:

```tsx
import { lazy, Suspense } from "react";
import { Outlet, useLocation } from "react-router";
import { parseSettingsHash } from "./settings-hash";

// Settings is a hash overlay, not a page: the route underneath stays mounted, so
// closing returns you exactly where you were. Mounted at the AuthGuard level
// rather than inside AppLayout because /link and /oauth/consent both link to
// `#settings/billing` and live outside the app shell.
const SettingsDialog = lazy(() => import("./settings-layout"));

export default function SettingsOverlayHost() {
	const { hash } = useLocation();
	const section = parseSettingsHash(hash);

	return (
		<>
			<Outlet />
			{section !== null && (
				<Suspense fallback={null}>
					<SettingsDialog section={section} />
				</Suspense>
			)}
		</>
	);
}
```

- [ ] **Step 4: Write the legacy redirect**

Create `backend/frontend/src/settings/legacy-settings-redirect.tsx`:

```tsx
import { Navigate, useLocation } from "react-router";
import { parseSettingsHash, settingsHash } from "./settings-hash";

// `/settings/*` was the old path route. Phoenix still serves the SPA for those
// paths (see router.ex) so existing bookmarks boot, and this bounces them to the
// hash form. Redirects to `/`, which VaultRedirect then resolves to the user's
// vault while preserving the hash.
export default function LegacySettingsRedirect() {
	const location = useLocation();
	const tail = location.pathname.replace(/^\/settings\/?/, "");
	const section = parseSettingsHash(tail === "" ? "#settings" : `#settings/${tail}`) ?? "account";

	return (
		<Navigate
			to={{ pathname: "/", search: location.search, hash: settingsHash(section) }}
			replace
		/>
	);
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd backend/frontend && bun run test -- settings-overlay-host`
Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
git add src/settings/settings-overlay-host.tsx src/settings/legacy-settings-redirect.tsx src/settings/settings-overlay-host.test.tsx
git commit -m "feat(settings): add hash overlay host and legacy redirect"
```

---

## Task 4: Wire the overlay into the router

**Files:**
- Modify: `backend/frontend/src/router.tsx`
- Modify: `backend/frontend/src/layout/app-shell.ts`
- Test: `backend/frontend/src/router.test.tsx` (create if absent)

**Interfaces:**
- Consumes: `SettingsOverlayHost`, `LegacySettingsRedirect` (Task 3).
- Produces: a router where `/settings` and `/settings/*` redirect, and every authenticated route can host the settings hash.

- [ ] **Step 1: Remove the settings path subtree**

In `backend/frontend/src/router.tsx`, delete the entire `settings` route object (lines 185-216: the `{ path: "settings", element: suspended(<SettingsLayout />), children: [...] }` block) from `AppLayout`'s children. Also delete these now-unused lazy declarations: `SettingsLayout` (lines 32-34), `BillingPage` (46), `AdminPanel` (47), `ConnectionsPage` (50), `VaultsPage` (51), and the `AccountPage` lazy inside `createAppRouter` (lines 116-120). Task 2 moved all of them into `settings-layout.tsx`.

This removes every use of `config` inside `createAppRouter` (the account-page branch at 116-120, `config.billingEnabled` at 209, `config.authProvider` at 212 were the only three). Keep the `createAppRouter(config: EngramConfig)` signature anyway: `main.tsx` and `BootstrapGate` call it with an argument. If biome flags the now-unused parameter, rename it to `_config` rather than changing the call sites.

- [ ] **Step 2: Add the host and the legacy redirect**

Add to the imports at the top of `router.tsx`:

```tsx
const SettingsOverlayHost = lazy(() => import("./settings/settings-overlay-host"));
const LegacySettingsRedirect = lazy(() => import("./settings/legacy-settings-redirect"));
```

Wrap the `AuthGuard` children in the host. The `AuthGuard` route object becomes:

```tsx
{
	element: <AuthGuard />,
	children: [
		{
			// Hash-addressed settings overlays EVERY authenticated route, including
			// /link and /oauth/consent which sit outside the app shell and link to
			// `#settings/billing`.
			element: suspendedScreen(<SettingsOverlayHost />),
			children: [
				// ...every existing AuthGuard child moves in here verbatim:
				// /onboard subtree, ROUTES.DEVICE_LINK, ROUTES.OAUTH_CONSENT,
				// and the OnboardingGate subtree.

				// Legacy path settings — Phoenix still serves the SPA for these
				// (router.ex) so old bookmarks boot and land on the hash form.
				{ path: "/settings", element: suspended(<LegacySettingsRedirect />) },
				{ path: "/settings/*", element: suspended(<LegacySettingsRedirect />) },
			],
		},
	],
},
```

- [ ] **Step 3: Remove the SettingsLayout barrel export**

In `backend/frontend/src/layout/app-shell.ts`, delete line 11:

```ts
export { default as SettingsLayout } from "../settings/settings-layout";
```

- [ ] **Step 4: Verify the build and full suite**

Run: `cd backend/frontend && bun run build && bun run test`
Expected: build succeeds with no unused-import errors; all tests pass. Any test that rendered the old `/settings/account` route will fail here. Update those to render `/` with `hash: "#settings/account"`.

- [ ] **Step 5: Commit**

```bash
git add src/router.tsx src/layout/app-shell.ts
git commit -m "feat(router): mount settings as a hash overlay"
```

---

## Task 5: Update frontend settings link sites

**Files:**
- Modify: `backend/frontend/src/layout/user-menu.tsx:55`, `layout/rail.tsx:20,64`, `layout/app-sidebar.tsx:19`, `layout/empty-vault-state.tsx:12`, `billing/upgrade-required-dialog.tsx:59`, `settings/vaults/active-vaults-section.tsx:129`, `settings/connections-page.tsx:199`, `settings/account/connected-accounts-section.tsx:89`, `device/device-link-page.tsx:234,236,254,256,304,307`, `oauth/oauth-authorize-page.tsx:261,264,363`
- Test: `backend/frontend/src/layout/rail.test.tsx`

**Interfaces:**
- Consumes: `settingsHash`, `isSettingsHash` (Task 1).
- Produces: no new exports.

Mechanical replacement, plus one real bug fix in `rail.tsx`.

- [ ] **Step 1: Write the failing rail test**

`rail.tsx:20` decides "is settings open" with `location.pathname.startsWith("/settings")` and `rail.tsx:26` responds to a view-button click with `navigate("/")`. That is the same lose-your-place bug as the dialog close. Add to `backend/frontend/src/layout/rail.test.tsx`:

```tsx
it("closes settings without leaving the current note", async () => {
	render(
		<MemoryRouter initialEntries={["/work/note-1#settings/account"]}>
			<LocationProbe />
			<RailViewProvider>
				<Rail />
			</RailViewProvider>
		</MemoryRouter>,
	);
	fireEvent.click(screen.getByRole("button", { name: /files/i }));
	expect(screen.getByTestId("loc")).toHaveTextContent("/work/note-1");
	expect(screen.getByTestId("loc")).not.toHaveTextContent("#settings");
});
```

Add a `LocationProbe` to the file if it does not already have one:

```tsx
function LocationProbe() {
	const loc = useLocation();
	return <output data-testid="loc">{`${loc.pathname}${loc.hash}`}</output>;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend/frontend && bun run test -- rail`
Expected: FAIL, location is `/` instead of `/work/note-1`.

- [ ] **Step 3: Fix rail.tsx**

Replace the `onSettings` derivation and `onClick` in `ViewButton`:

```tsx
const { view, setView } = useRailView();
const location = useLocation();
const navigate = useNavigate();
const onSettings = isSettingsHash(location.hash);
const active = view === id && !onSettings;
const onClick = () => {
	setView(id);
	if (onSettings) {
		// Strip the settings hash, stay on the page underneath.
		navigate({ pathname: location.pathname, search: location.search, hash: "" });
	}
};
```

Add `import { isSettingsHash } from "../settings/settings-hash";` and change the settings `NavLink` at line 64 from `to="/settings"` to `to={settingsHash("account")}` (importing `settingsHash` too). Because it is now a hash link, its `NavLink` active styling must also switch to `onSettings` rather than `isActive`; use a plain `Link` with `aria-current={onSettings ? "page" : undefined}` and the same className branch the other buttons use.

- [ ] **Step 4: Replace the remaining link sites**

Apply verbatim:

| File:line | From | To |
|---|---|---|
| `layout/user-menu.tsx:55` | `to="/settings"` | `to={settingsHash("account")}` |
| `layout/app-sidebar.tsx:19` | `to="/settings/billing"` | `to={settingsHash("billing")}` |
| `layout/empty-vault-state.tsx:12` | `to="/settings/vaults"` | `to={settingsHash("vaults")}` |
| `billing/upgrade-required-dialog.tsx:59` | `navigate("/settings/billing")` | `navigate({ hash: settingsHash("billing") })` |
| `settings/vaults/active-vaults-section.tsx:129` | `href="/settings/billing"` | `href={settingsHash("billing")}` |
| `settings/connections-page.tsx:199` | `href="/settings/billing"` | `href={settingsHash("billing")}` |
| `device/device-link-page.tsx:236,256,304` | `href="/settings/billing"` | `href={settingsHash("billing")}` |
| `device/device-link-page.tsx:234,254,307` | `navigate("/settings/billing")` | `navigate({ hash: settingsHash("billing") })` |
| `oauth/oauth-authorize-page.tsx:264` | `href="/settings/billing"` | `href={settingsHash("billing")}` |
| `oauth/oauth-authorize-page.tsx:261,363` | `navigate("/settings/billing")` | `navigate({ hash: settingsHash("billing") })` |
| `settings/account/connected-accounts-section.tsx:89` | `` `${window.location.origin}/settings/account` `` | `` `${window.location.origin}/${settingsHash("account")}` `` |

Add `import { settingsHash } from "@/settings/settings-hash";` (or the correct relative path) to each file.

Note the Clerk `redirectUrl` produces `https://host/#settings/account`. That is intentional: Clerk returns to the origin root and the SPA reopens the dialog from the hash.

- [ ] **Step 5: Verify no path references remain**

Run: `cd backend/frontend && grep -rn '"/settings\|`/settings\|to="/settings\|navigate("/settings' src/ --include=*.ts --include=*.tsx | grep -v legacy-settings-redirect | grep -v '\.test\.'`
Expected: no output.

- [ ] **Step 6: Run tests, lint, commit**

```bash
cd backend/frontend && bun run test && ./node_modules/.bin/biome ci
git add -A src/
git commit -m "refactor(settings): point all links at the hash"
```

---

## Task 6: Backend settings URLs

**Files:**
- Modify: `backend/lib/engram_web/plugs/enforce_pat_creation.ex:12,19`
- Modify: `backend/lib/engram_web/plugs/require_api_write_enabled.ex:10,48`
- Modify: `backend/lib/engram_web/plugs/enforce_connection_cap.ex:19`
- Modify: `backend/lib/engram/workers/vault_deleted_email.ex:42`
- Test: `backend/e2e/tests/api_only/test_71_connections.py:417,443,700`

**Interfaces:**
- Consumes: nothing.
- Produces: `upgrade_url` values now end with `/#settings/billing`.

- [ ] **Step 1: Update the e2e assertions first**

In `backend/e2e/tests/api_only/test_71_connections.py`, change all three assertions (lines 417, 443, 700) and their preceding comments from `"/settings/billing"` to `"/#settings/billing"`.

- [ ] **Step 2: Run to verify they fail**

Run: `cd backend && make ci-up && python -m pytest e2e/tests/api_only/test_71_connections.py -k upgrade -v`
Expected: FAIL, actual value is `/settings/billing`.

- [ ] **Step 3: Update the plugs**

In `enforce_pat_creation.ex`, change line 19 and the docstring on line 12:

```elixir
@upgrade_url "/#settings/billing"
```

In `require_api_write_enabled.ex`, change line 48 and the docstring on line 10:

```elixir
upgrade_url: "/#settings/billing"
```

In `enforce_connection_cap.ex`, change the docstring on line 19 to `"upgrade_url": "/#settings/billing"`.

- [ ] **Step 4: Update the vault-deleted email**

In `vault_deleted_email.ex:42`:

```elixir
# The section goes in the hash and `highlight` stays in the real query string:
# a query placed INSIDE a hash is not parsed by location.search, so the SPA
# would never see it.
manage_url = EngramWeb.Endpoint.url() <> "/?highlight=#{vault.id}#settings/vaults"
```

- [ ] **Step 5: Run to verify they pass**

Run: `cd backend && python -m pytest e2e/tests/api_only/test_71_connections.py -k upgrade -v && mix test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/engram_web/plugs/ lib/engram/workers/vault_deleted_email.ex e2e/tests/api_only/test_71_connections.py
git commit -m "fix(billing): emit hash-addressed settings URLs"
```

---

## Task 7: Phoenix deny-list and dynamic SPA routes

**Files:**
- Modify: `backend/lib/engram_web/router.ex:458-478`
- Modify: `backend/lib/engram_web/controllers/spa_controller.ex`
- Test: `backend/test/engram_web/controllers/spa_controller_test.exs` (create if absent)

**Interfaces:**
- Consumes: nothing.
- Produces: `SpaController.not_found/2`; SPA served for `/:slug` and `/:slug/:id`.

The SPA whitelist is deliberately not a catch-all (`router.ex:454-457`, per #858): unknown URLs must 404 rather than render HTML 200 over a typo'd API request. Adding `get "/:slug/:id"` breaks that, because a typo'd `/api/notez` is two segments with no matching API route. The deny-list restores the guarantee.

- [ ] **Step 1: Write the failing test**

Create `backend/test/engram_web/controllers/spa_controller_test.exs`:

```elixir
defmodule EngramWeb.SpaControllerTest do
  use EngramWeb.ConnCase, async: true

  describe "vault-scoped SPA routes" do
    test "serves the SPA for a bare vault slug", %{conn: conn} do
      conn = get(conn, "/my-vault")
      assert html_response(conn, 200) =~ "__ENGRAM_CONFIG__"
    end

    test "serves the SPA for a vault-scoped note", %{conn: conn} do
      conn = get(conn, "/my-vault/018f2b3c-0000-7000-8000-000000000000")
      assert html_response(conn, 200) =~ "__ENGRAM_CONFIG__"
    end
  end

  describe "non-SPA prefixes must not fall through to /:slug (#858)" do
    # Regression guard: without the deny-list these two-segment typos match
    # `get "/:slug/:id"` and return an HTML 200, masking a broken API call.
    test "a typo'd API path 404s instead of serving HTML", %{conn: conn} do
      conn = get(conn, "/api/notez")
      assert response(conn, 404)
      refute response_content_type(conn, :html) =~ "text/html"
    end

    test "a typo'd webhooks path 404s", %{conn: conn} do
      assert conn |> get("/webhooks/bogus") |> response(404)
    end

    test "a typo'd well-known path 404s", %{conn: conn} do
      assert conn |> get("/.well-known/bogus") |> response(404)
    end

    test "a typo'd oauth path 404s", %{conn: conn} do
      assert conn |> get("/oauth/bogus") |> response(404)
    end

    test "but /oauth/consent still serves the SPA", %{conn: conn} do
      conn = get(conn, "/oauth/consent")
      assert html_response(conn, 200) =~ "__ENGRAM_CONFIG__"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/engram_web/controllers/spa_controller_test.exs`
Expected: FAIL. The `/my-vault` cases raise `Phoenix.Router.NoRouteError`.

- [ ] **Step 3: Add the not_found action**

In `backend/lib/engram_web/controllers/spa_controller.ex`, add below `index/2`:

```elixir
  @doc """
  404 for non-SPA prefixes.

  The `/:slug` and `/:slug/:id` SPA routes are dynamic, so without an explicit
  deny-list ahead of them a typo'd `/api/notez` would match `/:slug/:id` and get
  an HTML 200, masking a broken API call. See router.ex and #858.
  """
  def not_found(conn, _params) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not Found")
  end
```

- [ ] **Step 4: Add the routes**

In `backend/lib/engram_web/router.ex`, inside the existing `scope "/", EngramWeb do pipe_through :spa`, append after the `get "/oauth/consent"` line and before the closing `end`:

```elixir
    # Deny-list. MUST stay above the dynamic /:slug routes below: those are
    # 1- and 2-segment wildcards, so without this a typo'd /api/notez would
    # match /:slug/:id and serve an HTML 200 (the exact regression #858
    # removed). EVERY new non-SPA top-level prefix must be added here.
    match :*, "/api/*path", SpaController, :not_found
    match :*, "/oauth/*path", SpaController, :not_found
    match :*, "/webhooks/*path", SpaController, :not_found
    match :*, "/.well-known/*path", SpaController, :not_found

    # Vault-scoped SPA routes. `/:slug` is a vault, `/:slug/:id` a note or
    # attachment. Kept last so every static route above wins.
    get "/:slug", SpaController, :index
    get "/:slug/:id", SpaController, :index
```

Leave `get "/settings"`, `get "/settings/*path"`, and `get "/note/*path"` in place: they serve the SPA so legacy bookmarks boot and get redirected client-side.

- [ ] **Step 5: Run test to verify it passes**

Run: `cd backend && mix test test/engram_web/controllers/spa_controller_test.exs`
Expected: PASS, 7 tests.

- [ ] **Step 6: Run the full backend suite**

Run: `cd backend && mix format && mix credo && mix test`
Expected: all green. If any existing test asserted a 404 for a path now matched by `/:slug`, it will fail here. Those are two-segment paths under a denied prefix (already covered) or genuine single-segment typos that now render the SPA and 404 client-side. Update the assertion to expect a 200 and note why.

- [ ] **Step 7: Commit**

```bash
git add lib/engram_web/router.ex lib/engram_web/controllers/spa_controller.ex test/engram_web/controllers/spa_controller_test.exs
git commit -m "feat(router): serve SPA at /:slug with a deny-list guard"
```

---

## Task 8: Reserved vault slugs

**Files:**
- Modify: `backend/lib/engram/vaults/vault.ex:34-56`
- Create: `backend/frontend/src/api/reserved-slugs.ts`
- Modify: `backend/frontend/src/components/vault-create-form.tsx`
- Test: `backend/test/engram/vaults/vault_test.exs`, `backend/frontend/src/api/reserved-slugs.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `RESERVED_SLUGS: readonly string[]` and `isReservedSlug(slug: string): boolean` from `api/reserved-slugs.ts`.

React Router ranks static segments above dynamic ones, so `/link` beats `/:slug` automatically. A vault slugged `link` would not crash the app, it would just be unreachable by URL. This is a UX guard, not a correctness fix.

- [ ] **Step 1: Write the failing Elixir test**

Add to `backend/test/engram/vaults/vault_test.exs` (create the file with `use Engram.DataCase, async: true` and `alias Engram.Vaults.Vault` if absent):

```elixir
  describe "reserved slugs" do
    @valid %{
      user_id: Ecto.UUID.generate(),
      name_ciphertext: <<1>>,
      name_nonce: <<2>>,
      name_hmac: <<3>>
    }

    test "rejects a slug that would be shadowed by a static SPA route" do
      for slug <- ~w(settings link oauth onboard note api sign-in) do
        cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, slug))
        refute cs.valid?, "expected #{slug} to be rejected"
        assert "is reserved" in errors_on(cs).slug
      end
    end

    test "accepts an ordinary slug" do
      cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, "work"))
      assert cs.valid?
    end

    test "rejection is case-insensitive" do
      cs = Vault.changeset(%Vault{}, Map.put(@valid, :slug, "Settings"))
      refute cs.valid?
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/engram/vaults/vault_test.exs`
Expected: FAIL, the changeset is valid for `settings`.

- [ ] **Step 3: Add the validation**

In `backend/lib/engram/vaults/vault.ex`, add above `def changeset`:

```elixir
  # Slugs that a static SPA route would shadow. React Router ranks static
  # segments above `/:slug`, so a vault named one of these would not break the
  # app, it would simply be unreachable by URL. Keep in sync with
  # frontend/src/api/reserved-slugs.ts.
  @reserved_slugs ~w(
    sign-in sign-up waitlist link oauth onboard reset-password
    note search billing settings api webhooks .well-known
  )
```

And in the changeset pipeline, between `validate_required` and the first `unique_constraint`:

```elixir
    |> update_change(:slug, &String.downcase/1)
    |> validate_exclusion(:slug, @reserved_slugs, message: "is reserved")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test test/engram/vaults/vault_test.exs`
Expected: PASS.

- [ ] **Step 5: Mirror the list on the frontend**

Create `backend/frontend/src/api/reserved-slugs.ts`:

```ts
// Mirror of @reserved_slugs in lib/engram/vaults/vault.ex. Duplicated because
// the check spans two languages; the backend changeset is authoritative and
// this exists only to fail fast in the create/rename form.
export const RESERVED_SLUGS: readonly string[] = [
	"sign-in",
	"sign-up",
	"waitlist",
	"link",
	"oauth",
	"onboard",
	"reset-password",
	"note",
	"search",
	"billing",
	"settings",
	"api",
	"webhooks",
	".well-known",
];

export function isReservedSlug(slug: string): boolean {
	return RESERVED_SLUGS.includes(slug.trim().toLowerCase());
}
```

Create `backend/frontend/src/api/reserved-slugs.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { isReservedSlug } from "./reserved-slugs";

describe("isReservedSlug", () => {
	it("rejects reserved slugs regardless of case or padding", () => {
		expect(isReservedSlug("settings")).toBe(true);
		expect(isReservedSlug("Settings")).toBe(true);
		expect(isReservedSlug("  link  ")).toBe(true);
	});

	it("accepts ordinary slugs", () => {
		expect(isReservedSlug("work")).toBe(false);
		expect(isReservedSlug("settings-archive")).toBe(false);
	});
});
```

- [ ] **Step 6: Wire it into the create form**

In `backend/frontend/src/components/vault-create-form.tsx`, add the import and reject before submit, surfacing the message next to the slug field:

```tsx
import { isReservedSlug } from "@/api/reserved-slugs";

// ...inside the submit handler, before the mutation call:
if (isReservedSlug(slug)) {
	setSlugError(`"${slug}" is reserved and would make the vault unreachable by URL.`);
	return;
}
```

If the form has no `slugError` state, add `const [slugError, setSlugError] = useState<string | null>(null);` and render it with the same markup the form's other field errors use. Clear it at the top of the handler.

- [ ] **Step 7: Run tests, lint, commit**

```bash
cd backend && mix format && mix test test/engram/vaults/vault_test.exs
cd frontend && bun run test -- reserved-slugs && ./node_modules/.bin/biome ci
git add -A
git commit -m "feat(vaults): reject reserved slugs"
```

---

## Task 9: Vault slug resolution helpers

**Files:**
- Create: `backend/frontend/src/api/vault-slug.ts`
- Test: `backend/frontend/src/api/vault-slug.test.ts`

**Interfaces:**
- Consumes: `Vault` from `api/queries.ts`.
- Produces: `vaultBySlug(vaults: Vault[] | undefined, slug: string | undefined): Vault | null`; `preferredVault(vaults: Vault[] | undefined, hintId: string | null): Vault | null`.

- [ ] **Step 1: Write the failing test**

Create `backend/frontend/src/api/vault-slug.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import type { Vault } from "./queries";
import { preferredVault, vaultBySlug } from "./vault-slug";

function v(id: string, slug: string, is_default = false): Vault {
	return { id, slug, is_default, name: slug } as Vault;
}

const vaults = [v("id-a", "work"), v("id-b", "personal", true), v("id-c", "archive")];

describe("vaultBySlug", () => {
	it("finds a vault by slug", () => {
		expect(vaultBySlug(vaults, "personal")?.id).toBe("id-b");
	});

	it("returns null for an unknown slug", () => {
		expect(vaultBySlug(vaults, "nope")).toBeNull();
	});

	it("returns null when vaults or slug are missing", () => {
		expect(vaultBySlug(undefined, "work")).toBeNull();
		expect(vaultBySlug(vaults, undefined)).toBeNull();
	});
});

describe("preferredVault", () => {
	it("prefers the hinted vault", () => {
		expect(preferredVault(vaults, "id-c")?.slug).toBe("archive");
	});

	it("falls back to the default when the hint is stale", () => {
		expect(preferredVault(vaults, "id-gone")?.slug).toBe("personal");
	});

	it("falls back to the default when there is no hint", () => {
		expect(preferredVault(vaults, null)?.slug).toBe("personal");
	});

	it("falls back to the first vault when none is marked default", () => {
		expect(preferredVault([v("id-a", "work"), v("id-c", "archive")], null)?.slug).toBe("work");
	});

	it("returns null when there are no vaults", () => {
		expect(preferredVault([], null)).toBeNull();
		expect(preferredVault(undefined, "id-a")).toBeNull();
	});
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend/frontend && bun run test -- vault-slug`
Expected: FAIL, "Failed to resolve import ./vault-slug".

- [ ] **Step 3: Write minimal implementation**

Create `backend/frontend/src/api/vault-slug.ts`:

```ts
import type { Vault } from "./queries";

export function vaultBySlug(vaults: Vault[] | undefined, slug: string | undefined): Vault | null {
	if (!vaults || !slug) {
		return null;
	}
	return vaults.find((v) => v.slug === slug) ?? null;
}

// Used only where the URL does NOT name a vault: the bare `/` redirect and the
// legacy `/note/:id` redirect. `hintId` is the last-used vault (localStorage via
// the active-vault store); it is a hint, not authority, so a stale id silently
// degrades to the default vault.
export function preferredVault(vaults: Vault[] | undefined, hintId: string | null): Vault | null {
	if (!vaults || vaults.length === 0) {
		return null;
	}
	return (
		(hintId ? vaults.find((v) => v.id === hintId) : undefined) ??
		vaults.find((v) => v.is_default) ??
		vaults[0] ??
		null
	);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend/frontend && bun run test -- vault-slug`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add src/api/vault-slug.ts src/api/vault-slug.test.ts
git commit -m "feat(vaults): add slug resolution helpers"
```

---

## Task 10: VaultRoute, VaultRedirect, LegacyNoteRedirect

**Files:**
- Create: `backend/frontend/src/viewer/vault-route.tsx`
- Create: `backend/frontend/src/viewer/vault-redirect.tsx`
- Create: `backend/frontend/src/viewer/legacy-note-redirect.tsx`
- Test: `backend/frontend/src/viewer/vault-route.test.tsx`

**Interfaces:**
- Consumes: `vaultBySlug`, `preferredVault` (Task 9); `useVaults` from `api/queries`; `getActiveVaultId`, `setActiveVaultId`, `useActiveVaultId` from `api/active-vault`; `NotFoundPage` from `../not-found`; `LoadingPane` from `./loading-pane`; `EmptyVaultState` from `../layout/empty-vault-state`.
- Produces: three default-exported components.

- [ ] **Step 1: Write the failing test**

Create `backend/frontend/src/viewer/vault-route.test.tsx`:

```tsx
import { render, screen } from "@testing-library/react";
import { MemoryRouter, Route, Routes, useLocation } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { getActiveVaultId, setActiveVaultId } from "../api/active-vault";
import LegacyNoteRedirect from "./legacy-note-redirect";
import VaultRedirect from "./vault-redirect";
import VaultRoute from "./vault-route";

const vaults = [
	{ id: "id-a", slug: "work", is_default: false, name: "Work" },
	{ id: "id-b", slug: "personal", is_default: true, name: "Personal" },
];

let mockVaults: unknown[] | undefined = vaults;
let mockPending = false;

vi.mock("../api/queries", () => ({
	useVaults: () => ({ data: mockVaults, isPending: mockPending }),
}));

function LocationProbe() {
	const loc = useLocation();
	return <output data-testid="loc">{`${loc.pathname}${loc.search}${loc.hash}`}</output>;
}

// Records the active vault id at RENDER time, not in an effect, so the test can
// prove no child ever renders under the wrong vault.
function VaultProbe() {
	return <output data-testid="child">{String(getActiveVaultId())}</output>;
}

beforeEach(() => {
	mockVaults = vaults;
	mockPending = false;
	setActiveVaultId(null);
});

describe("VaultRoute", () => {
	function renderRoute(entry: string) {
		return render(
			<MemoryRouter initialEntries={[entry]}>
				<Routes>
					<Route path="/:slug" element={<VaultRoute />}>
						<Route index element={<VaultProbe />} />
					</Route>
				</Routes>
			</MemoryRouter>,
		);
	}

	it("resolves the slug and renders children under that vault", async () => {
		renderRoute("/work");
		expect(await screen.findByTestId("child")).toHaveTextContent("id-a");
	});

	it("never renders children under the previous vault", async () => {
		setActiveVaultId("id-b");
		renderRoute("/work");
		const child = await screen.findByTestId("child");
		// If VaultRoute rendered its Outlet before the store caught up, this
		// would have been "id-b" for one pass and ~25 queries would have fired
		// against the wrong vault.
		expect(child).toHaveTextContent("id-a");
	});

	it("404s on an unknown slug", () => {
		renderRoute("/nope");
		expect(screen.queryByTestId("child")).toBeNull();
		expect(screen.getByText(/not found/i)).toBeInTheDocument();
	});

	it("waits rather than 404ing while the vault list is loading", () => {
		mockVaults = undefined;
		mockPending = true;
		renderRoute("/work");
		expect(screen.queryByText(/not found/i)).toBeNull();
		expect(screen.queryByTestId("child")).toBeNull();
	});
});

describe("VaultRedirect", () => {
	function renderRedirect(entry: string) {
		return render(
			<MemoryRouter initialEntries={[entry]}>
				<LocationProbe />
				<Routes>
					<Route path="/" element={<VaultRedirect />} />
					<Route path="/:slug" element={<p>vault page</p>} />
				</Routes>
			</MemoryRouter>,
		);
	}

	it("redirects to the hinted vault", async () => {
		setActiveVaultId("id-a");
		renderRedirect("/");
		expect(await screen.findByTestId("loc")).toHaveTextContent("/work");
	});

	it("redirects to the default vault with no hint", async () => {
		renderRedirect("/");
		expect(await screen.findByTestId("loc")).toHaveTextContent("/personal");
	});

	it("preserves search and hash across the bounce", async () => {
		renderRedirect("/?highlight=abc#settings/vaults");
		expect(await screen.findByTestId("loc")).toHaveTextContent(
			"/personal?highlight=abc#settings/vaults",
		);
	});

	it("renders the empty state when there are no vaults", () => {
		mockVaults = [];
		renderRedirect("/");
		expect(screen.getByText(/no vaults/i)).toBeInTheDocument();
	});
});

describe("LegacyNoteRedirect", () => {
	it("rewrites /note/:id to /:slug/:id using the hinted vault", async () => {
		setActiveVaultId("id-a");
		render(
			<MemoryRouter initialEntries={["/note/n-1"]}>
				<LocationProbe />
				<Routes>
					<Route path="/note/:id" element={<LegacyNoteRedirect />} />
					<Route path="/:slug/:itemId" element={<p>note page</p>} />
				</Routes>
			</MemoryRouter>,
		);
		expect(await screen.findByTestId("loc")).toHaveTextContent("/work/n-1");
	});
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend/frontend && bun run test -- vault-route`
Expected: FAIL, "Failed to resolve import ./legacy-note-redirect".

- [ ] **Step 3: Write VaultRoute**

Create `backend/frontend/src/viewer/vault-route.tsx`:

```tsx
import { useEffect } from "react";
import { Outlet, useParams } from "react-router";
import { setActiveVaultId, useActiveVaultId } from "../api/active-vault";
import { useVaults } from "../api/queries";
import { vaultBySlug } from "../api/vault-slug";
import NotFoundPage from "../not-found";
import LoadingPane from "./loading-pane";

// The URL is the source of truth for the active vault. This is the ONLY place
// that writes the store from a route; ~30 consumers (queries.ts, use-channel,
// folder-tree, trace, remote-log) read it unchanged.
export default function VaultRoute() {
	const { slug } = useParams();
	const { data: vaults, isPending } = useVaults();
	const activeId = useActiveVaultId();
	const vault = vaultBySlug(vaults, slug);

	useEffect(() => {
		if (vault) {
			setActiveVaultId(vault.id);
		}
	}, [vault]);

	// The list is normally already warm: useAppBootstrap seeds ["vaults"] and
	// runs in OnboardingGate, above this route. This only gates a genuine cold
	// fetch, and must come before the 404 so a slow list is not mistaken for a
	// bad slug.
	if (isPending && !vaults) {
		return <LoadingPane />;
	}
	if (!vault) {
		return <NotFoundPage />;
	}
	// Load-bearing: the effect above lands AFTER this render. Without the hold,
	// one pass escapes with the PREVIOUS vault id and every descendant query and
	// the channel join fire against the wrong vault.
	if (activeId !== vault.id) {
		return <LoadingPane />;
	}
	return <Outlet />;
}
```

- [ ] **Step 4: Write VaultRedirect and LegacyNoteRedirect**

Create `backend/frontend/src/viewer/vault-redirect.tsx`:

```tsx
import { Navigate, useLocation } from "react-router";
import { getActiveVaultId } from "../api/active-vault";
import { useVaults } from "../api/queries";
import { preferredVault } from "../api/vault-slug";
import { EmptyVaultState } from "../layout/empty-vault-state";
import LoadingPane from "./loading-pane";

// Bare `/` does not name a vault, so pick one: last-used, else default, else
// first. Search and hash are carried across so links like
// `/?highlight=<id>#settings/vaults` (the vault-deleted email) survive.
export default function VaultRedirect() {
	const { data: vaults, isPending } = useVaults();
	const location = useLocation();

	if (isPending && !vaults) {
		return <LoadingPane />;
	}
	const vault = preferredVault(vaults, getActiveVaultId());
	if (!vault) {
		return <EmptyVaultState />;
	}
	return (
		<Navigate
			to={{ pathname: `/${vault.slug}`, search: location.search, hash: location.hash }}
			replace
		/>
	);
}
```

Create `backend/frontend/src/viewer/legacy-note-redirect.tsx`:

```tsx
import { Navigate, useLocation, useParams } from "react-router";
import { getActiveVaultId } from "../api/active-vault";
import { useVaults } from "../api/queries";
import { preferredVault } from "../api/vault-slug";
import NotFoundPage from "../not-found";
import LoadingPane from "./loading-pane";

// Old `/note/:id` links. A note id alone does not name its vault, so this is
// best effort: resolve the last-used vault and rewrite. If the note actually
// lives elsewhere the note fetch 404s, which is exactly what happened before
// this change, so no regression. A server-side note-to-vault lookup would make
// it exact and is deliberately out of scope.
export default function LegacyNoteRedirect() {
	const { id } = useParams();
	const { data: vaults, isPending } = useVaults();
	const location = useLocation();

	if (isPending && !vaults) {
		return <LoadingPane />;
	}
	const vault = preferredVault(vaults, getActiveVaultId());
	if (!vault || !id) {
		return <NotFoundPage />;
	}
	return (
		<Navigate
			to={{ pathname: `/${vault.slug}/${id}`, search: location.search, hash: location.hash }}
			replace
		/>
	);
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd backend/frontend && bun run test -- vault-route`
Expected: PASS, 9 tests.

- [ ] **Step 6: Commit**

```bash
git add src/viewer/vault-route.tsx src/viewer/vault-redirect.tsx src/viewer/legacy-note-redirect.tsx src/viewer/vault-route.test.tsx
git commit -m "feat(vaults): add URL-driven vault resolution routes"
```

---

## Task 11: Wire vault routes into the router

**Files:**
- Modify: `backend/frontend/src/router.tsx`

**Interfaces:**
- Consumes: `VaultRoute`, `VaultRedirect`, `LegacyNoteRedirect` (Task 10).
- Produces: live `/:slug` and `/:slug/:itemId` routes.

- [ ] **Step 1: Add the lazy imports**

In `backend/frontend/src/router.tsx`, next to the other lazy declarations:

```tsx
const VaultRoute = lazy(() => import("./viewer/vault-route"));
const VaultRedirect = lazy(() => import("./viewer/vault-redirect"));
const LegacyNoteRedirect = lazy(() => import("./viewer/legacy-note-redirect"));
```

- [ ] **Step 2: Replace AppLayout's children**

Replace the `AppLayout` children array (which after Task 4 holds only `ROUTES.HOME` and `/note/:id`) with:

```tsx
children: [
	// Bare `/` picks a vault; `/note/:id` is the pre-vault-scoping URL shape.
	{ path: ROUTES.HOME, element: suspended(<VaultRedirect />) },
	{ path: "/note/:id", element: suspended(<LegacyNoteRedirect />) },
	// Vault-scoped. Kept LAST so every static route above wins RR's
	// static-over-dynamic ranking.
	{
		path: "/:slug",
		element: suspended(<VaultRoute />),
		children: [
			{ index: true, element: suspended(<Dashboard />) },
			{ path: ":itemId", element: suspended(<VaultItemPage />) },
		],
	},
],
```

- [ ] **Step 3: Update the VaultItemPage param name**

`VaultItemPage` reads `const { id } = useParams()` (`vault-item-page.tsx:18`). The param is now `itemId`. Change it to `const { itemId: id } = useParams();` and update the comment on line 11 from `/note/:id` to `/:slug/:itemId`.

Check `note-page.tsx` and `attachment-page.tsx` for their own `useParams()` calls and apply the same rename. Run `cd backend/frontend && grep -rn 'useParams' src/viewer/` to find them all.

- [ ] **Step 4: Verify build and full suite**

Run: `cd backend/frontend && bun run build && bun run test`
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add src/router.tsx src/viewer/
git commit -m "feat(router): serve notes at /:slug/:itemId"
```

---

## Task 12: Vault-scoped note links and vault switching

**Files:**
- Modify: `backend/frontend/src/layout/vault-switcher.tsx`
- Modify: `backend/frontend/src/layout/search-panel.tsx:170`, `api/queries.ts:626`, `viewer/dashboard.tsx:24`, `viewer/tree/tree-row.tsx:230,273`
- Modify: `backend/frontend/src/onboarding/onboarding-shell.tsx:37`, `onboarding/tour/controller.tsx:35`
- Test: `backend/frontend/src/layout/vault-switcher.test.tsx`

**Interfaces:**
- Consumes: `useVaults`, `useActiveVaultId`, `vaultBySlug`.
- Produces: no new exports.

Every note link needs the active vault's slug. Add a tiny hook rather than repeating the lookup at six sites.

- [ ] **Step 1: Add the hook**

Append to `backend/frontend/src/api/vault-slug.ts`:

```ts
import { useActiveVaultId } from "./active-vault";
import { useVaults } from "./queries";

// Slug of the vault currently in the store, for building note hrefs. Returns
// null only before the vault list lands, which in practice does not happen
// inside AppLayout (useAppBootstrap seeds it above).
export function useActiveVaultSlug(): string | null {
	const vaults = useVaults().data;
	const activeId = useActiveVaultId();
	return vaults?.find((v) => v.id === activeId)?.slug ?? null;
}
```

Add a test to `vault-slug.test.ts` is not required here; the hook is exercised by the link-site tests below and by `vault-switcher.test.tsx`.

- [ ] **Step 2: Write the failing switcher test**

Add to `backend/frontend/src/layout/vault-switcher.test.tsx`:

```tsx
it("navigates to the new vault instead of writing the store directly", async () => {
	render(
		<MemoryRouter initialEntries={["/work/note-1"]}>
			<LocationProbe />
			<VaultSwitcher />
		</MemoryRouter>,
	);
	fireEvent.click(screen.getByRole("button", { name: /vault/i }));
	fireEvent.click(screen.getByRole("menuitemradio", { name: /personal/i }));
	// Switching vaults leaves the old note behind: its id is meaningless in the
	// new vault, so land on the vault root.
	expect(screen.getByTestId("loc")).toHaveTextContent("/personal");
	expect(screen.getByTestId("loc")).not.toHaveTextContent("note-1");
});
```

Add a `LocationProbe` to the file if absent (same shape as Task 5).

- [ ] **Step 3: Run test to verify it fails**

Run: `cd backend/frontend && bun run test -- vault-switcher`
Expected: FAIL, location stays `/work/note-1`.

- [ ] **Step 4: Rework the switcher**

In `backend/frontend/src/layout/vault-switcher.tsx`:

Delete the reconciliation effect at lines 19-31 entirely. `VaultRedirect` now owns choosing a vault when none is valid, and it does so by navigating rather than writing the store.

Replace the `onValueChange` handler:

```tsx
onValueChange={(next) => {
	if (next === active.id) {
		return;
	}
	const target = vaults.find((v) => v.id === next);
	if (!target) {
		return;
	}
	// Navigate; VaultRoute writes the active-vault store. Land on the vault
	// root, not the current note, whose id does not exist in the new vault.
	navigate(`/${target.slug}`);
	qc.invalidateQueries();
	// Onboarding tour gates step 0 on a real switch; emit a DOM event the
	// controller can listen for without coupling layers.
	window.dispatchEvent(
		new CustomEvent("engram:vault-switched", { detail: { from: active.id, to: next } }),
	);
}}
```

Add `import { useNavigate } from "react-router";` and `const navigate = useNavigate();`. Remove the now-unused `setActiveVaultId` import.

- [ ] **Step 5: Update the note link sites**

In each file, get the slug with `const slug = useActiveVaultSlug();` and build the href. Where `slug` can be null, fall back to the legacy shape so the link still resolves through `LegacyNoteRedirect` rather than producing `/null/<id>`:

| File:line | From | To |
|---|---|---|
| `layout/search-panel.tsx:170` | `` const href = `/note/${result.id}` `` | `` const href = slug ? `/${slug}/${result.id}` : `/note/${result.id}` `` |
| `viewer/dashboard.tsx:24` | ``to={`/note/${note.id}`}`` | ``to={slug ? `/${slug}/${note.id}` : `/note/${note.id}`}`` |
| `viewer/tree/tree-row.tsx:230,273` | ``to={`/note/${item.id}`}`` | ``to={slug ? `/${slug}/${item.id}` : `/note/${item.id}`}`` |

`api/queries.ts:626` is inside a mutation callback, not a component, so it cannot use the hook. Change `navigate(\`/note/${id}\`)` to use the vault already in scope at that call site:

```ts
// vaultId is already resolved in this mutation's closure; look up its slug from
// the cache rather than re-deriving it.
const slug = qc.getQueryData<Vault[]>(["vaults"])?.find((v) => v.id === vaultId)?.slug;
navigate(slug ? `/${slug}/${id}` : `/note/${id}`);
```

- [ ] **Step 6: Update the tour comments**

Comments only. There is no `/note/` path logic anywhere in `src/onboarding/`: every navigation there targets `/` or `/onboard/*`, and `/` now routes through `VaultRedirect`, so the tour needs no behavioral change. The demo vaults already carry distinct slugs (`queries.ts:1205,1212`), so demo routing works unmodified.

- `onboarding-shell.tsx:37`: change `` The tour walks through a demo note (`/note/<id>`) that doesn't exist `` to `` The tour walks through a demo note (`/<slug>/<id>`) that doesn't exist ``
- `tour/controller.tsx:35`: change `we're on /note/<id> and Joyride times out waiting for that target.` to `we're on /<slug>/<id> and Joyride times out waiting for that target.`

Verify nothing else: `grep -rn '/note' src/onboarding/` should return only these two lines before the edit and nothing after.

- [ ] **Step 7: Verify no stale note links remain**

Run: `cd backend/frontend && grep -rn '`/note/' src/ --include=*.tsx --include=*.ts | grep -v legacy-note-redirect | grep -v '\.test\.'`
Expected: only the fallback branches added above.

- [ ] **Step 8: Run tests, lint, commit**

```bash
cd backend/frontend && bun run test && bun run build && ./node_modules/.bin/biome ci
git add -A src/
git commit -m "feat(vaults): make note links vault-scoped"
```

---

## Task 13: E2E helper and full verification

**Files:**
- Modify: `backend/e2e/helpers/web_spa.py:66,78`

**Interfaces:**
- Consumes: nothing.
- Produces: no new exports.

`open_note(note_id, vault_id)` already seeds `engram.activeVaultId` before sign-in, so `LegacyNoteRedirect` resolves the right slug and rewrites the URL. Only the post-sign-in URL assertion needs to accept the rewritten shape.

- [ ] **Step 1: Widen the wait_for_url assertion**

In `backend/e2e/helpers/web_spa.py`, replace line 78:

```python
        # The seeded activeVaultId lets LegacyNoteRedirect rewrite /note/<id> to
        # /<vault-slug>/<id>, so match on the id with a boundary rather than the
        # old fixed /note/ prefix. Accepts both shapes.
        await page.wait_for_url(
            re.compile(rf"/{re.escape(str(note_id))}(?:[?#]|$)"), timeout=15_000
        )
```

Update the docstring on line 57 to say it opens the note at its vault-scoped URL.

- [ ] **Step 2: Run the E2E suite**

```bash
cd /home/open-claw/documents/code-projects/engram-workspace
make ci-up
make e2e
```

Expected: green. If a test fails on a URL assertion, fix the assertion; do not loosen a behavioral assert.

- [ ] **Step 3: Manual smoke against saas-dev**

```bash
cd /home/open-claw/documents/code-projects/engram-workspace
make saas-dev BACKEND_DIR=~/documents/code-projects/engram/.worktrees/feat-vault-scoped-urls
```

Walk through and confirm each:

1. Sign in, land on `/<your-default-slug>`.
2. Open a note, URL is `/<slug>/<uuid>`.
3. Open settings from the note. URL gains `#settings/account`, the note stays visible behind the dialog.
4. Close settings. You are back on the note, not the dashboard.
5. Browser Back reopens settings; Forward closes it again.
6. Switch vaults. URL becomes `/<other-slug>`, the tree reloads, no 404s in the network panel.
7. Paste `/<other-slug>/<a-note-id-from-the-first-vault>`. You get a note-not-found, not a blank page.
8. Hard-refresh on `/<slug>/<uuid>`. The SPA boots (this exercises the new Phoenix route).
9. Visit `/settings/billing`. You are redirected to `/<slug>#settings/billing`.
10. Visit `/note/<uuid>`. You are redirected to `/<slug>/<uuid>`.
11. Visit `/api/notez`. You get a plain-text 404, NOT the SPA.
12. Try creating a vault with slug `settings`. The form rejects it.

- [ ] **Step 4: Full gauntlet**

```bash
cd backend && mix format && mix credo && mix dialyzer && mix test
cd frontend && bun run test && bun run build && ./node_modules/.bin/biome ci
```

Expected: all green.

- [ ] **Step 5: Commit and open the PR**

```bash
git add e2e/helpers/web_spa.py
git commit -m "test(e2e): accept vault-scoped note URLs"
git push -u origin feat/vault-scoped-urls
gh pr create --title "feat: vault-scoped SPA URLs + settings hash overlay" --body "..."
```

PR body must state: the URL is now the source of truth for the active vault; settings moved from a path route to a `#settings/<section>` overlay; and the Phoenix deny-list is a standing obligation, so any future non-SPA top-level prefix must be added to it.

---

## Self-Review Notes

Spec sections mapped to tasks:

| Spec section | Task(s) |
|---|---|
| Direction of data flow | 9, 10, 11, 12 |
| Route tree | 4, 11 |
| `VaultRoute` incl. hold-until-resolved | 10 |
| `VaultRedirect`, `LegacyNoteRedirect` | 10 |
| `LegacySettingsRedirect` | 3 |
| `SettingsOverlayHost` | 3, 4 |
| Settings overlay behavior | 1, 2 |
| Vault switching | 12 |
| Demo vaults / tour | 12 |
| Phoenix routing + deny-list | 7 |
| Reserved slugs | 8 |
| Backend link updates | 6 |
| Frontend link updates | 5, 12 |
| Testing (frontend unit) | 1, 2, 3, 5, 9, 10, 12 |
| Testing (backend) | 6, 7, 8 |
| Testing (E2E) | 13 |

Deviation from the spec worth noting: the spec listed `useActiveVaultSlug` nowhere; it was added in Task 12 to avoid repeating the same vault lookup at six link sites. It is a thin wrapper over `useVaults` and `useActiveVaultId`, both already in the spec.
