# PostHog Funnel Instrumentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the signup-to-activation funnel visible in PostHog, without any user content or raw email leaving the product.

**Architecture:** The server mints a keyed pseudonymous id (`HMAC-SHA256(key, normalised email)`) and returns it on `GET /me`; the SPA identifies with it and emits ~18 explicit events through a validator that rejects any property value that isn't a UUID, enum member, boolean, number or known error code. Traffic reaches PostHog through a first-party `/ph` proxy on the SPA's Cloudflare Worker, which strips every IP-bearing header.

**Tech Stack:** Elixir/Phoenix, React + TypeScript + Vite, Cloudflare Workers, PostHog, Vitest, ExUnit.

**Spec:** Engram vault `50 Engineering/_Superpowers Specs/2026-09-17-posthog-funnel-instrumentation-design.md`

**Depends on:** `engram-infra` plan (all tasks) — `HMAC_KEY_ANALYTICS_ID`, `POSTHOG_PERSONAL_API_KEY` and `POSTHOG_PROJECT_ID` must reach the container first.

## Global Constraints

- **Never send user content to PostHog.** No note title, body, path, folder name, vault name, tag, filename, or search query — ever, in any property, on any event. Task 6's validator is the enforcement; treat a failing validator test as a release blocker.
- **Never send a raw email to PostHog.** `posthog.identify` takes one argument.
- **Self-host must emit nothing.** `Dockerfile:42-46` exists so self-host bundles don't carry the SaaS token. Do NOT pass `VITE_POSTHOG_KEY` to the Docker build; the SaaS SPA is built in the Cloudflare pipeline.
- **Do not change** `persistence: "memory"`, `autocapture: false`, `capture_pageview: false`, `capture_pageleave: false` or `disable_session_recording: true` in `frontend/src/main.tsx`. These are load-bearing for the no-consent-banner decision (`engram-workspace/docs/context/cookie-audit-2026-05-24.md`).
- Identifier normalisation is exactly `email |> String.trim() |> String.downcase()`, output lowercase hex. It must match `engram-marketing`'s `analyticsId()` byte for byte.
- Backend gauntlet before every push: `mise exec -- mix format`, `mix credo --strict`, `mix dialyzer`, `mix test`.
- Frontend: `bun run build` (tsc + vite) and `bun run test` before every commit.

---

### Task 1: Mint the analytics identifier server-side

**Files:**
- Modify: `lib/engram/observability/posthog.ex`
- Modify: `config/config.exs:307` area
- Modify: `config/runtime.exs:605-612` area
- Test: `test/engram/observability/posthog_test.exs`

**Interfaces:**
- Produces: `Engram.Observability.PostHog.analytics_id(email :: String.t()) :: String.t()` — 64 lowercase hex chars. Consumed by Tasks 2, 3 and 4.

- [ ] **Step 1: Write the failing test**

Create or extend `test/engram/observability/posthog_test.exs`:

```elixir
defmodule Engram.Observability.PostHogTest do
  use ExUnit.Case, async: true

  alias Engram.Observability.PostHog

  # Pins the algorithm. NOTE: this was originally a cross-repo contract with
  # engram-marketing, but that repo's waitlist and src/lib/hash-email.ts were
  # deleted in #189 — there is no marketing counterpart to match any more.
  # Keep the vector anyway: it is what catches a normalisation change.
  @key "dGVzdC1rZXktZG8tbm90LXVzZS1pbi1wcm9kdWN0aW9uLg=="
  @email "sabio@web.de"

  setup do
    prev = Application.get_env(:engram, :hmac_key_analytics_id)
    Application.put_env(:engram, :hmac_key_analytics_id, @key)
    on_exit(fn -> Application.put_env(:engram, :hmac_key_analytics_id, prev) end)
    :ok
  end

  test "normalises by trimming and downcasing" do
    assert PostHog.analytics_id("  Sabio@Web.DE  ") == PostHog.analytics_id(@email)
  end

  test "returns 64 lowercase hex characters" do
    assert PostHog.analytics_id(@email) =~ ~r/^[0-9a-f]{64}$/
  end

  test "is keyed, not a bare digest" do
    plain = :crypto.hash(:sha256, @email) |> Base.encode16(case: :lower)
    refute PostHog.analytics_id(@email) == plain
  end

  test "a different key yields a different id" do
    first = PostHog.analytics_id(@email)
    Application.put_env(:engram, :hmac_key_analytics_id, "b3RoZXIta2V5LW90aGVyLWtleS0xMjM0NTY3OA==")
    refute PostHog.analytics_id(@email) == first
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- mix test test/engram/observability/posthog_test.exs`
Expected: FAIL — `function PostHog.analytics_id/1 is undefined`.

- [ ] **Step 3: Implement**

Add to `lib/engram/observability/posthog.ex`:

```elixir
  @doc """
  Pseudonymous analytics identifier for an email address.

  Keyed, not a bare digest: an email is a low-entropy enumerable input, so an
  unsalted SHA-256 of one is reversible with a wordlist and would not be
  pseudonymisation in any meaningful sense.

  Normalisation and output format are pinned by a test vector. They were once a
  cross-repo contract with `engram-marketing`; that repo's waitlist and its
  email hashing were deleted in #189, so nothing external depends on this
  format today. If a second producer ever appears, it must match this exactly.

  The key is deliberately NON-ROTATING: rotating it re-identifies every person
  in PostHog and orphans all history.
  """
  @spec analytics_id(String.t()) :: String.t()
  def analytics_id(email) when is_binary(email) do
    key = Application.fetch_env!(:engram, :hmac_key_analytics_id)

    :crypto.mac(:hmac, :sha256, key, email |> String.trim() |> String.downcase())
    |> Base.encode16(case: :lower)
  end
```

- [ ] **Step 4: Wire the config**

In `config/config.exs`, beside the existing `:hmac_key_user_id` line:

```elixir
config :engram, :hmac_key_analytics_id, "dev-analytics-key-do-not-use-in-prod"
```

In `config/runtime.exs`, mirroring the `:hmac_key_user_id` block at ~line 605:

```elixir
    case System.get_env("HMAC_KEY_ANALYTICS_ID") do
      nil ->
        # Self-host and dev: analytics is off anyway (no posthog_key), so a
        # random per-boot key is correct — it can never collide with the SaaS
        # namespace even if a key is later set.
        config :engram, :hmac_key_analytics_id, Base.encode64(:crypto.strong_rand_bytes(32))

      key ->
        config :engram, :hmac_key_analytics_id, key
    end
```

- [ ] **Step 5: Run it and watch it pass**

Run: `mise exec -- mix test test/engram/observability/posthog_test.exs`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add lib/engram/observability/posthog.ex config/config.exs config/runtime.exs test/engram/observability/posthog_test.exs
git commit -m "feat(analytics): mint a keyed pseudonymous analytics id"
```

---

### Task 2: Switch every server-side event to the new identifier

**Files:**
- Modify: `lib/engram/search.ex:229`
- Modify: `lib/engram/notes.ex:522`, `lib/engram/notes.ex:4101`
- Modify: `lib/engram_web/webhooks/posthog_forwarder.ex:35,41,64`
- Modify: `lib/engram_web/controllers/vaults_controller.ex:133`
- Modify: `lib/engram/observability/posthog.ex` (moduledoc)
- Test: `test/engram_web/webhooks/posthog_forwarder_test.exs`

**Interfaces:**
- Consumes: `PostHog.analytics_id/1` from Task 1.

- [ ] **Step 1: Read every call site before changing any of them**

```bash
grep -rn "PostHog.capture" lib/
```

Each currently passes a Clerk id or a user struct field. Every one must pass `PostHog.analytics_id(user.email)` instead. The webhook forwarder is the awkward one — it receives a Clerk/Paddle payload, so confirm an email is available there before editing; if a handler has only a Clerk id, load the user first.

- [ ] **Step 2: Write the failing forwarder test**

In `test/engram_web/webhooks/posthog_forwarder_test.exs`, assert the distinct id is the HMAC and not the Clerk id:

```elixir
test "user_signed_up is keyed by the analytics id, not the clerk id" do
  user = insert_user(email: "sabio@web.de", external_id: "user_3J50JyLu")

  assert captured_distinct_id_for(user) == Engram.Observability.PostHog.analytics_id(user.email)
  refute captured_distinct_id_for(user) == user.external_id
end
```

Implement `captured_distinct_id_for/1` against whatever capture-interception helper this suite already uses; if none exists, add a `:posthog_key` override plus a Bypass endpoint, following the pattern in the nearest existing webhook test.

- [ ] **Step 3: Run it and watch it fail**

Run: `mise exec -- mix test test/engram_web/webhooks/posthog_forwarder_test.exs`
Expected: FAIL — the distinct id is still `user_3J50JyLu`.

- [ ] **Step 4: Change all six call sites**

Replace the distinct-id argument at each of the lines listed under **Files**. Do not change event names or properties.

- [ ] **Step 5: Correct the moduledoc**

`lib/engram/observability/posthog.ex`'s moduledoc still says "for SaaS users that's the Clerk user id". Replace that clause with "the keyed analytics id — see `analytics_id/1`". A stale moduledoc here is how the next person reintroduces the Clerk id.

- [ ] **Step 6: Run the suite and commit**

```bash
mise exec -- mix test
mise exec -- mix format && mise exec -- mix credo --strict
git add lib/ test/
git commit -m "refactor(analytics): key server events by the analytics id"
```

---

### Task 3: Return the identifier on GET /me

**Files:**
- Modify: `lib/engram_web/controllers/users_controller.ex:18-29`
- Test: `test/engram_web/controllers/users_controller_test.exs`

**Interfaces:**
- Produces: `GET /api/me` response gains `user.analytics_id`. Consumed by Task 5.

- [ ] **Step 1: Write the failing test**

```elixir
test "me/2 returns the analytics id even when onboarding is incomplete", %{conn: conn} do
  # Load-bearing: /api/me is on the user-scoped pipeline, which runs Auth but
  # NOT RequireOnboarding. The entire funnel we are trying to measure happens
  # BEFORE onboarding completes, so if this ever moves behind the gate the
  # instrumentation goes dark for exactly the users it exists to observe.
  user = insert_user(email: "sabio@web.de", terms_accepted_at: nil)

  body = conn |> authed(user) |> get(~p"/api/me") |> json_response(200)

  assert body["user"]["analytics_id"] == Engram.Observability.PostHog.analytics_id(user.email)
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- mix test test/engram_web/controllers/users_controller_test.exs`
Expected: FAIL — `analytics_id` is `nil`.

- [ ] **Step 3: Implement**

In `users_controller.ex`, add one key to the `json/2` map in `me/2`:

```elixir
        analytics_id: Engram.Observability.PostHog.analytics_id(user.email),
```

- [ ] **Step 4: Update the OpenAPI schema**

`Schemas.UserResponse` gains an `analytics_id` string property. Then regenerate:

```bash
mise exec -- env MIX_ENV=test mix openapi.spec.json --spec EngramWeb.ApiSpec --pretty=true openapi.json
```

The generated file is `openapi.json` at the REPO ROOT — not `priv/static/`.
A stale one fails CI at `verify.yml:2503-2515`; see
`engram-workspace/docs/context/self-host-capability-polarity.md`.

- [ ] **Step 5: Run it and watch it pass, then commit**

```bash
mise exec -- mix test test/engram_web/controllers/users_controller_test.exs
git add lib/engram_web/ test/engram_web/ openapi.json
git commit -m "feat(api): return analytics_id on GET /me"
```

---

### Task 4: Delete analytics data when an account is erased (GDPR Art. 17)

**Files:**
- Modify: `lib/engram/accounts/lifecycle.ex`
- Modify: `lib/engram/observability/posthog.ex`
- Modify: `config/runtime.exs`
- Test: `test/engram/accounts/lifecycle_test.exs`

**Interfaces:**
- Consumes: `PostHog.analytics_id/1`, `POSTHOG_PERSONAL_API_KEY`, `POSTHOG_PROJECT_ID`.
- Produces: `PostHog.delete_person(distinct_id :: String.t()) :: :ok`.

**Why this task exists:** verified on 2026-09-17, an account hard-deleted on 2026-09-14 still had a live PostHog person three days later. Erasure currently covers Clerk, Postgres, Qdrant and S3 and misses analytics entirely.

- [ ] **Step 1: Write the failing test**

```elixir
test "hard_delete removes the PostHog person" do
  user = insert_user(email: "sabio@web.de")
  bypass = Bypass.open()
  # PostHog deletes by person UUID, so the flow is: look up by distinct_id,
  # then DELETE that uuid with delete_events=true.
  Bypass.expect_once(bypass, "GET", "/api/projects/1/persons/", fn conn ->
    Plug.Conn.resp(conn, 200, ~s({"results":[{"id":"00000000-0000-0000-0000-0000000000ab"}]}))
  end)
  Bypass.expect_once(bypass, "DELETE", "/api/projects/1/persons/00000000-0000-0000-0000-0000000000ab/", fn conn ->
    Plug.Conn.resp(conn, 204, "")
  end)

  assert {:ok, _} = Lifecycle.hard_delete(user, "user_requested")
end

test "hard_delete tolerates a person that does not exist" do
  user = insert_user(email: "gone@example.com")
  bypass = Bypass.open()
  Bypass.expect_once(bypass, "GET", "/api/projects/1/persons/", fn conn ->
    Plug.Conn.resp(conn, 200, ~s({"results":[]}))
  end)

  # A missing person is success, exactly like the Clerk 404 case.
  assert {:ok, _} = Lifecycle.hard_delete(user, "user_requested")
end
```

Point `:posthog_host` at `"http://localhost:#{bypass.port}"` and set `:posthog_project_id` to `"1"` in the test setup.

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- mix test test/engram/accounts/lifecycle_test.exs`
Expected: FAIL — Bypass reports no request was made.

- [ ] **Step 3: Implement `delete_person/1`**

Add to `lib/engram/observability/posthog.ex`:

```elixir
  @doc """
  Delete a PostHog person and their events by distinct_id.

  Called from account erasure. A person that does not exist is SUCCESS, not an
  error — same tolerance as the Clerk delete, which already treats 404 as done.
  Requires a personal API key with person:write scope; the capture key cannot
  delete.
  """
  @spec delete_person(String.t()) :: :ok
  def delete_person(distinct_id) when is_binary(distinct_id) do
    with {key, host, project} <- admin_config(),
         {:ok, %{status: 200, body: %{"results" => [%{"id" => id} | _]}}} <-
           Req.get("#{host}/api/projects/#{project}/persons/",
             params: [distinct_id: distinct_id],
             auth: {:bearer, key}
           ) do
      _ =
        Req.delete("#{host}/api/projects/#{project}/persons/#{id}/",
          params: [delete_events: true],
          auth: {:bearer, key}
        )

      :ok
    else
      _ -> :ok
    end
  end
```

Add an `admin_config/0` private function mirroring the existing `config/0`, reading `:posthog_personal_api_key` and `:posthog_project_id`, returning `:disabled` when either is unset. Wire both from `POSTHOG_PERSONAL_API_KEY` / `POSTHOG_PROJECT_ID` in `config/runtime.exs`.

- [ ] **Step 4: Call it from erasure**

In `lib/engram/accounts/lifecycle.ex`'s `hard_delete/2`, immediately after the block commented `# Step 3: S3 prefixes` and before the Clerk identity step:

```elixir
    # Step 3b: analytics. Right to erasure covers PostHog too — this was
    # missing until 2026-09-17, so accounts erased before then still have live
    # person records. Best-effort and non-blocking, same as Qdrant and S3.
    _ = PostHog.delete_person(PostHog.analytics_id(user.email))
```

Also delete the legacy Clerk-id-keyed person, since every person created before this work is keyed that way:

```elixir
    _ = if user.external_id, do: PostHog.delete_person(user.external_id), else: :ok
```

- [ ] **Step 5: Run it and watch it pass**

Run: `mise exec -- mix test test/engram/accounts/lifecycle_test.exs`
Expected: PASS.

- [ ] **Step 6: Update the moduledoc and commit**

`lifecycle.ex`'s moduledoc line 7 lists the stores a hard delete purges: "sessions, Paddle, Qdrant, S3, PG, Clerk". Add PostHog to that list — the list is how the next person checks coverage.

```bash
mise exec -- mix test && mise exec -- mix format && mise exec -- mix credo --strict
git add lib/ config/ test/
git commit -m "fix(privacy): delete PostHog person on account erasure"
```

---

### Task 5: Identify with the new id and stop sending email

**Files:**
- Modify: `frontend/src/auth/use-identify-user-on-auth-change.ts`
- Modify: `frontend/src/auth/use-identify-user-on-auth-change.test.ts`

**Interfaces:**
- Consumes: `analytics_id` from `GET /me` (Task 3).

- [ ] **Step 1: Write the failing test**

Add to the existing test file:

```ts
it("identifies with the analytics id and never with an email", () => {
	renderHook(() =>
		useIdentifyUserOnAuthChange({
			isLoaded: true,
			isSignedIn: true,
			analyticsId: "a".repeat(64),
			id: "user_3J50JyLu",
			email: "sabio@web.de",
		}),
	);

	expect(posthog.identify).toHaveBeenCalledWith("a".repeat(64));
	// One argument only. A second argument is how a raw email reaches PostHog,
	// and our privacy policy says it does not.
	expect(vi.mocked(posthog.identify).mock.calls[0]).toHaveLength(1);
});

it("does not identify before the analytics id has loaded", () => {
	renderHook(() =>
		useIdentifyUserOnAuthChange({ isLoaded: true, isSignedIn: true, id: "user_3J50JyLu" }),
	);
	expect(posthog.identify).not.toHaveBeenCalled();
});
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd frontend && bun run test src/auth/use-identify-user-on-auth-change.test.ts`
Expected: FAIL — called with two arguments, the second containing the email.

- [ ] **Step 3: Implement**

Change the hook's params to take `analyticsId?: string` and replace the identify branch:

```ts
		if (isSignedIn && analyticsId) {
			posthog.identify(analyticsId);
			// Id only — never email, and never the Clerk id. See the privacy
			// policy's sub-processor table.
			setSentryUser(id ?? null);
		} else if (!isSignedIn) {
```

Keep `email` out of the parameter list entirely so it cannot be passed by accident. Update the caller in `clerk-auth-provider.tsx` to source `analyticsId` from the `GET /me` query.

- [ ] **Step 4: Run it and watch it pass, then commit**

```bash
bun run test && bun run build
git add src/auth/
git commit -m "feat(analytics): identify by analytics id, never by email"
```

---

### Task 6: The event layer and its property validator

**Files:**
- Create: `frontend/src/analytics/events.ts`
- Create: `frontend/src/analytics/track.ts`
- Create: `frontend/src/analytics/track.test.ts`

**Interfaces:**
- Produces: `track(event: EngramEvent, props?: Record<string, unknown>): void` and the `EngramEvent` union. Consumed by Task 7.

- [ ] **Step 1: Write the failing validator test**

Create `frontend/src/analytics/track.test.ts`:

```ts
import { describe, expect, it, vi } from "vitest";
import posthog from "posthog-js";
import { track } from "./track";

vi.mock("posthog-js", () => ({ default: { capture: vi.fn() } }));

describe("track property validation", () => {
	it("allows uuids, enum members, booleans and numbers", () => {
		track("onboarding_step_viewed", {
			step: "billing",
			vault_id: "12dc6735-52f2-4ce4-9117-91f0ce2389a7",
			is_retry: false,
			duration_ms: 1420,
		});
		expect(posthog.capture).toHaveBeenCalledOnce();
	});

	it.each([
		["a note title", { step: "vault", title: "My private journal" }],
		["a vault path", { step: "vault", path: "Work/2026/Q3 review.md" }],
		["a search query", { step: "done", query: "salary negotiation" }],
		["a raw email", { step: "done", email: "sabio@web.de" }],
	])("rejects %s", (_label, props) => {
		expect(() => track("onboarding_step_viewed", props)).toThrow(/not an allowed/i);
	});
});
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd frontend && bun run test src/analytics/track.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement the event union**

Create `frontend/src/analytics/events.ts`:

```ts
/** Every event this app may emit. Adding one here is a deliberate act —
 *  see the property rules in track.ts before you do. */
export type EngramEvent =
	| "onboarding_step_viewed"
	| "onboarding_step_completed"
	| "onboarding_blocked"
	| "plugin_connect_started"
	| "plugin_connect_succeeded"
	| "plugin_connect_failed"
	| "vault_first_sync_completed"
	| "checkout_opened"
	| "checkout_stalled"
	| "checkout_completed"
	| "checkout_abandoned"
	| "mcp_connect_attempted"
	| "mcp_connect_succeeded"
	| "mcp_connect_failed";

/** Mirrors Engram.Onboarding.gate/2's next_step. One state machine, not two. */
export type OnboardingStep = "agreement" | "billing" | "tools" | "vault" | "done";

export const ONBOARDING_STEPS: readonly OnboardingStep[] = [
	"agreement",
	"billing",
	"tools",
	"vault",
	"done",
] as const;

export const CHECKOUT_METHODS = ["card", "apple_pay", "google_pay", "paypal", "unknown"] as const;

export const MCP_CLIENTS = ["chatgpt", "claude", "cursor", "other"] as const;
```

- [ ] **Step 4: Implement the validator**

Create `frontend/src/analytics/track.ts`:

```ts
import posthog from "posthog-js";
import { CHECKOUT_METHODS, type EngramEvent, MCP_CLIENTS, ONBOARDING_STEPS } from "./events";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const ENUM_VALUES: ReadonlySet<string> = new Set([
	...ONBOARDING_STEPS,
	...CHECKOUT_METHODS,
	...MCP_CLIENTS,
	// Error codes, deliberately enumerated. An unrecognised code is dropped
	// rather than forwarded, because "error detail" is where free text hides.
	"onboarding_required",
	"gate_closed",
	"not_found",
	"rate_limited",
	"network",
	"timeout",
	"unknown",
]);

/** A property value is allowed ONLY if it is provably not user content.
 *
 *  This product stores people's private notes. The failure mode we are
 *  designing against is not malice, it is a future `{ title }` added to an
 *  event in a hurry. An allowlist fails closed; a denylist would not. */
function isAllowed(value: unknown): boolean {
	if (typeof value === "boolean") return true;
	if (typeof value === "number") return Number.isFinite(value);
	if (Array.isArray(value)) return value.every(isAllowed);
	if (typeof value === "string") return UUID.test(value) || ENUM_VALUES.has(value);
	return false;
}

export function track(event: EngramEvent, props: Record<string, unknown> = {}): void {
	for (const [key, value] of Object.entries(props)) {
		if (isAllowed(value)) continue;

		const message = `analytics: property "${key}" on "${event}" is not an allowed value type`;
		if (import.meta.env.DEV) throw new Error(message);
		console.warn(message);
		return; // Drop the whole event in prod. A partial event is a silent lie.
	}

	posthog.capture(event, props);
}
```

- [ ] **Step 5: Run it and watch it pass**

Run: `cd frontend && bun run test src/analytics/track.test.ts`
Expected: PASS, 5 tests.

- [ ] **Step 6: Commit**

```bash
git add src/analytics/
git commit -m "feat(analytics): typed event emitter with a property allowlist"
```

---

### Task 7: Emit the events

**Files:**
- Modify: `frontend/src/onboarding/onboarding-shell.tsx`, `agreement-page.tsx`, `onboard-tools-page.tsx`, `create-first-vault-modal.tsx`
- Modify: `frontend/src/` billing/checkout page (the `@paddle/paddle-js` caller)
- Test: `frontend/src/onboarding/onboarding-shell.test.tsx`

**Interfaces:**
- Consumes: `track` and `EngramEvent` from Task 6.

- [ ] **Step 1: Write the failing step test**

```tsx
it("emits onboarding_step_viewed once per step", () => {
	const { rerender } = render(<OnboardingShell step="agreement" />);
	rerender(<OnboardingShell step="agreement" />);
	expect(track).toHaveBeenCalledTimes(1);

	rerender(<OnboardingShell step="billing" />);
	expect(track).toHaveBeenLastCalledWith("onboarding_step_viewed", { step: "billing" });
});
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd frontend && bun run test src/onboarding/onboarding-shell.test.tsx`
Expected: FAIL — `track` not called.

- [ ] **Step 3: Emit from the shell**

In `onboarding-shell.tsx`, one effect keyed on the step so a re-render does not double-fire:

```tsx
useEffect(() => {
	track("onboarding_step_viewed", { step });
}, [step]);
```

- [ ] **Step 4: Emit the 403 blocker**

Wherever the SPA handles a `403 onboarding_required` response, emit:

```ts
track("onboarding_blocked", { missing: body.missing, next_step: body.next_step });
```

`missing` is an array of enum members, which the validator accepts via its array branch. This is the event that would have shown dgonzalez stuck for two days.

- [ ] **Step 5: Emit the checkout lifecycle**

In the Paddle checkout caller, map the Paddle.js event callbacks:

| Paddle event | Emit |
|---|---|
| `checkout.loaded` | `checkout_opened` with `{ method: "unknown", tier }` |
| `checkout.payment.selected` | update the tracked method |
| `checkout.payment.failed` or a payment left in `action_required` | `checkout_stalled` with `{ method }` |
| `checkout.completed` | `checkout_completed` with `{ method, tier }` |
| `checkout.closed` without completion | `checkout_abandoned` with `{ method }` |

`checkout_stalled` is the one that would have caught the four dead Apple Pay attempts on 2026-09-06.

- [ ] **Step 6: Emit plugin-connect and MCP events**

`plugin_connect_started` / `_succeeded` / `_failed` around the device-link flow, and `mcp_connect_attempted` / `_succeeded` / `_failed` with `{ client }` mapped through `MCP_CLIENTS` — any unrecognised host becomes `"other"`, never the raw hostname.

- [ ] **Step 7: Run it, build, commit**

```bash
bun run test && bun run build
git add src/
git commit -m "feat(analytics): emit the onboarding and activation funnel"
```

---

### Task 8: First-party /ph proxy on the SPA Worker

**Files:**
- Modify: `frontend/worker/index.ts`
- Modify: `frontend/wrangler.jsonc`
- Test: `frontend/worker/index.test.ts` (create)

**Interfaces:**
- Produces: `POST app.engram.page/ph/*` → `us.i.posthog.com/*`, IP headers stripped.

- [ ] **Step 1: Write the failing test**

```ts
it("strips IP-bearing headers and passes cf-ipcountry", async () => {
	const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("ok"));
	await worker.fetch(
		new Request("https://app.engram.page/ph/capture/", {
			method: "POST",
			headers: { "cf-connecting-ip": "203.0.113.9", "cf-ipcountry": "DE", "cf-ipcity": "Berlin" },
			body: "{}",
		}),
		envStub,
	);

	const sent = fetchSpy.mock.calls[0][0] as Request;
	expect(sent.headers.get("cf-connecting-ip")).toBeNull();
	expect(sent.headers.get("cf-ipcity")).toBeNull();
	expect(sent.headers.get("cf-ipcountry")).toBe("DE");
});

it("returns 204 without forwarding when Sec-GPC is 1", async () => {
	const fetchSpy = vi.spyOn(globalThis, "fetch");
	const res = await worker.fetch(
		new Request("https://app.engram.page/ph/capture/", {
			method: "POST",
			headers: { "sec-gpc": "1" },
			body: "{}",
		}),
		envStub,
	);
	expect(res.status).toBe(204);
	expect(fetchSpy).not.toHaveBeenCalled();
});
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd frontend && bun run test worker/index.test.ts`
Expected: FAIL — the request falls through to `env.ASSETS.fetch`.

- [ ] **Step 3: Implement**

Port `marketing/src/lib/posthog-proxy.ts` into `frontend/worker/index.ts`: copy its `STRIPPED_REQUEST_HEADERS` set verbatim, keep `cf-ipcountry` passing through, and branch on `pathname.startsWith("/ph/")` before the existing MCP branch. Add the `sec-gpc` check as the first statement in that branch.

- [ ] **Step 4: Widen the Worker route**

In `frontend/wrangler.jsonc`, `assets.run_worker_first` currently reads `["/api/mcp", "/api/mcp/*"]`. The Worker does not run for any other path, so without this the proxy is dead code:

```jsonc
		"run_worker_first": ["/api/mcp", "/api/mcp/*", "/ph", "/ph/*"]
```

- [ ] **Step 5: Run it and watch it pass, then commit**

```bash
bun run test worker/index.test.ts && bun run build
git add worker/ wrangler.jsonc
git commit -m "feat(analytics): first-party /ph proxy on the SPA worker"
```

---

### Task 9: Turn it on in prod, and prove self-host stays off

**Files:**
- Modify: `frontend/src/main.tsx:68-83`
- Modify: `frontend/.env.production`
- Modify: `.github/workflows/verify.yml:5471` area
- Modify: `.github/workflows/frontend-promote.yml:80` area
- Test: `frontend/src/main.posthog.test.ts` (create)

- [ ] **Step 1: Write the failing init test**

```ts
it("does not init when the GPC signal is set", async () => {
	Object.defineProperty(navigator, "globalPrivacyControl", { value: true, configurable: true });
	await initAnalytics("phc_test");
	expect(posthog.init).not.toHaveBeenCalled();
});

it("uses identified_only person profiles", async () => {
	await initAnalytics("phc_test");
	expect(posthog.init).toHaveBeenCalledWith(
		"phc_test",
		expect.objectContaining({ person_profiles: "identified_only", persistence: "memory" }),
	);
});

it("does nothing at all without a key (the self-host shape)", async () => {
	await initAnalytics("");
	expect(posthog.init).not.toHaveBeenCalled();
});
```

Extract the current inline `if (posthogKey) { ... }` block in `main.tsx` into an exported `initAnalytics(key: string)` so it is testable; call it from `main.tsx` exactly as before.

- [ ] **Step 2: Run it and watch it fail**

Run: `cd frontend && bun run test src/main.posthog.test.ts`
Expected: FAIL — `initAnalytics` is not exported.

- [ ] **Step 3: Implement**

Extract `initAnalytics`, add `person_profiles: "identified_only"` and the GPC guard, and leave every other option untouched:

```ts
export async function initAnalytics(key: string): Promise<void> {
	if (!key) return;
	// GPC has legal force under CCPA/CPRA and is what our privacy policy
	// promises. posthog's respect_dnt covers the deprecated DNT header only.
	if ((navigator as { globalPrivacyControl?: boolean }).globalPrivacyControl === true) return;

	const { default: posthog } = await import("posthog-js");
	posthog.init(key, {
		api_host: import.meta.env.VITE_POSTHOG_HOST ?? "/ph",
		persistence: "memory",
		person_profiles: "identified_only",
		autocapture: false,
		capture_pageview: false,
		capture_pageleave: false,
		disable_session_recording: true,
		respect_dnt: true,
	});
}
```

- [ ] **Step 4: Set the host in the committed env file**

`frontend/.env.production` is the single source of truth for non-secret `VITE_*` (see the comment at `verify.yml:5459`). Add:

```
VITE_POSTHOG_HOST=/ph
```

- [ ] **Step 5: Pass the key in both prod build paths**

In `verify.yml`, in the `Build (saas)` step's `env:` block beside `VITE_SENTRY_DSN`:

```yaml
          # Product analytics. Publishable (ships in the browser) but stored as
          # a secret to match engram-marketing's PUBLIC_POSTHOG_KEY precedent.
          # Deliberately NOT passed to the Docker build: that image runs
          # build:selfhost, and Dockerfile:42-46 exists so self-host bundles
          # never carry the SaaS token.
          VITE_POSTHOG_KEY: ${{ secrets.VITE_POSTHOG_KEY }}
```

Add the identical line to `frontend-promote.yml`'s rebuild step. That step claims to be "byte-identical" to the deploy build — if only one gets the key, the self-heal path silently ships a bundle with analytics off.

- [ ] **Step 6: Prove self-host emits nothing**

This is a build-output assertion, not a unit test, so it runs as a shell check
rather than through vitest. `build:selfhost` (`frontend/package.json:17`) runs
`vite build --mode selfhost` and never loads `.env.production`, so no
`VITE_POSTHOG_*` value can reach it.

```bash
cd frontend
VITE_POSTHOG_KEY=phc_thisMustNotAppear bun run build:selfhost
# Both greps must find nothing. `grep -r` exits 1 on no-match, which is success
# here, so invert it explicitly rather than relying on the exit code.
if grep -rq "phc_thisMustNotAppear" dist/; then echo "FAIL: key leaked into self-host bundle"; exit 1; fi
if grep -rq "us\.i\.posthog\.com" dist/; then echo "FAIL: posthog host in self-host bundle"; exit 1; fi
echo "OK: self-host bundle is clean"
```

Add that block as a step in whichever CI job already builds self-host, so the
`Dockerfile:42-46` intent is guarded by a check rather than a comment.

- [ ] **Step 7: Set the repo secret**

```bash
gh secret set VITE_POSTHOG_KEY --repo engram-app/engram --body "<the phc_ project key>"
```

- [ ] **Step 8: Run everything and commit**

```bash
bun run test && bun run build
git add src/main.tsx src/main.posthog.test.ts .env.production ../.github/workflows/verify.yml ../.github/workflows/frontend-promote.yml
git commit -m "feat(analytics): enable PostHog in the prod SPA build"
```

- [ ] **Step 9: Verify in prod after deploy**

```bash
# Expect a 204 for the GPC case and a 200 otherwise.
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://app.engram.page/ph/capture/ -H 'sec-gpc: 1' -d '{}'
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://app.engram.page/ph/capture/ -d '{}'
```

Then sign in as a test user and confirm one person appears in PostHog with a 64-hex distinct id and **no** `email` property.

- [ ] **Step 10: Close the deferred cookie-audit row**

Re-run the audit recipe in `engram-workspace/docs/context/cookie-audit-2026-05-24.md` against **signed-in** `app.engram.page` — the surface that audit explicitly deferred and the one this work instruments. Add the results as a new dated section, and record that `/ph` is first-party so no new third-party script was introduced.
