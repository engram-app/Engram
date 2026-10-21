import { setupClerkTestingToken } from "@clerk/testing/playwright";
import { devices, expect, type Page, test } from "@playwright/test";
import { clerkSignIn, loadAuthState } from "./clerk-helpers";
import { clerkFetch } from "./support/clerk-fetch";

/**
 * An MCP-first signup completes onboarding and resumes the authorization.
 *
 * A user can reach `/oauth/consent` having just signed up inside the OAuth
 * flow itself, with no terms accepted, no plan and no vault. Approving in that
 * state used to mint a grant the vault gate refused on every subsequent call —
 * valid tokens, permanent 403, nothing in the response saying what to do
 * (#1666). One real user burned five hours against that wall.
 *
 * This is the only test that reaches an un-onboarded user THROUGH THE OAUTH
 * CONSENT PATH. Un-onboarded users themselves are not new: local-auth.spec.ts
 * registers them and walks the whole wizard. What no fixture could produce is
 * one who arrives mid-authorization, because every OAuth fixture
 * (global-setup.ts, e2e/helpers/oauth.py, e2e/helpers/clerk_auth.py)
 * pre-completes onboarding before the first assertion. That is the gap the
 * bug shipped through.
 *
 * The user is provisioned HERE rather than in global-setup, because the test
 * consumes it: finishing the wizard is the thing under test, so a second
 * attempt against the same user would find nothing to bounce. Per-attempt
 * provisioning is what makes the spec survive Playwright's retry.
 *
 * It is also the only place the SPA talks to the real backend across this
 * path. The consent page's unit test mocks `../api/oauth`, so nothing else
 * verifies that `/api/oauth/clients/:id?redirect_uri=` really returns `slug`
 * in the shape the page reads, or that the browser's pre-answer POST lands
 * and drops the `tools` step from the chain.
 *
 * Note: this test creates a vault and a welcome note, and `notes_user_id_fkey`
 * has no ON DELETE CASCADE, so `db-cleanup.ts`'s single `DELETE FROM users`
 * aborts and logs `DB cleanup failed - FK constraints on test users` at
 * console.error. Because it is ONE statement covering every e2e email
 * pattern, that abort deletes nobody, not just this spec's row.
 *
 * That is survivable only because the e2e-browser Postgres is per-run
 * ephemeral (PG_CONTAINER is keyed on github.run_id and torn down under
 * `if: always()`), so nothing accumulates between runs. Do NOT reuse this
 * reasoning for a suite that runs against a persistent database: there the
 * same abort would strand every test user until the MAX_ROWS_DELETED cap
 * tripped and cleanup refused to run at all.
 */

const CLERK_API = "https://api.clerk.com/v1";
const CLERK_BACKEND_PORT = process.env.PW_CLERK_BACKEND_PORT ?? "4001";
const CLERK_VITE_PORT = process.env.PW_CLERK_VITE_PORT ?? "5174";
const SECRET_KEY = process.env.E2E_CLERK_SECRET_KEY ?? "";

// Loopback on the SPA's own origin, so approving cannot navigate the browser
// off-box. The page 404s; the assertion is on the URL, which is where the
// authorization code is delivered.
const CALLBACK_PATH = "/oauth-callback-test";
const REDIRECT_URI = `http://localhost:${CLERK_VITE_PORT}${CALLBACK_PATH}`;

// "Claude Code" normalizes to the `claude_code` catalog slug via
// LogoAllowlist's client_name fallback — the path loopback clients take, since
// a loopback redirect cannot be host-verified. That resolved slug is what lets
// the wizard skip its tool question.
const CLIENT_NAME = "Claude Code";

const STATE = "e2e-consent-state-8f21";

// 43 chars of base64url. The backend validates PKCE shape at the authorize and
// consent endpoints; the verifier is only needed at token exchange, which this
// test does not reach.
const CODE_CHALLENGE = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";

async function registerClient(): Promise<string> {
	const resp = await fetch(`http://localhost:${CLERK_BACKEND_PORT}/oauth/register`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ redirect_uris: [REDIRECT_URI], client_name: CLIENT_NAME }),
	});

	if (!resp.ok) {
		throw new Error(`DCR registration failed: ${resp.status} ${await resp.text()}`);
	}

	const body = await resp.json();
	if (!body.client_id) {
		throw new Error(`DCR returned no client_id: ${JSON.stringify(body)}`);
	}
	return body.client_id as string;
}

/** A fresh Clerk user with NO onboarding performed. The omission is the point. */
async function createUnonboardedUser(): Promise<{ email: string; id: string }> {
	const ts = Date.now();
	const email = `e2e-browser-pending-${ts}@test.com`;

	const resp = await clerkFetch(`${CLERK_API}/users`, {
		method: "POST",
		headers: {
			Authorization: `Bearer ${SECRET_KEY}`,
			"Content-Type": "application/json",
		},
		body: JSON.stringify({
			email_address: [email],
			username: `e2e-pending-${ts}`,
			password: `pw-${ts}-${Math.random().toString(36).slice(2)}`,
			skip_password_checks: true,
		}),
	});

	if (!resp.ok) {
		throw new Error(`Clerk pending-user creation failed: ${resp.status} ${await resp.text()}`);
	}

	const user = await resp.json();

	// No readiness probe here. Clerk's user-list and sign-in-token endpoints can
	// sit on different read replicas (#455), but `clerkSignIn` already rides
	// that out: it retries specifically on "No user found" for ~20s with
	// backoff, which is that lookup lagging. Exporting global-setup's probes to
	// duplicate the wait would also put mid-file exports in a module the linter
	// requires to keep its exports last.
	return { email, id: user.id as string };
}

function consentUrl(clientId: string): string {
	const params = new URLSearchParams({
		client_id: clientId,
		redirect_uri: REDIRECT_URI,
		response_type: "code",
		code_challenge: CODE_CHALLENGE,
		code_challenge_method: "S256",
		state: STATE,
		scope: "mcp",
	});
	return `/oauth/consent?${params.toString()}`;
}

test.describe("MCP-first signup resumes consent after onboarding", () => {
	const state = loadAuthState();
	const skip = state.skipped || !SECRET_KEY;

	let pending: { email: string; id: string } | null = null;

	test.skip(() => skip, "E2E_CLERK_SECRET_KEY not set — Clerk browser tests skipped");

	test.beforeEach(async ({ page }) => {
		if (skip) {
			return;
		}
		// Per-attempt, not beforeAll: a retry needs its own un-onboarded user.
		pending = await createUnonboardedUser();
		await setupClerkTestingToken({ page });
	});

	test.afterEach(async () => {
		if (!pending) {
			return;
		}
		// Teardown must not fail the test, but it must not be mute either. A
		// Clerk 429 RESOLVES with a non-ok Response rather than throwing, so a
		// bare `.catch()` sees nothing and the user leaks silently. This suite
		// has hit Clerk's quota before, and it surfaces as unrelated specs
		// failing to create users much later.
		await clerkFetch(`${CLERK_API}/users/${pending.id}`, {
			method: "DELETE",
			headers: { Authorization: `Bearer ${SECRET_KEY}` },
		})
			.then((resp) => {
				if (!resp.ok) {
					console.warn(`clerk teardown failed for ${pending?.id}: ${resp.status}`);
				}
			})
			.catch((err) => console.warn(`clerk teardown errored for ${pending?.id}: ${String(err)}`));
		pending = null;
	});

	test("consent → wizard → back to consent → approve", async ({ page }) => {
		await approveThroughOnboarding(page, (pending as { email: string }).email);
	});

	test.describe("on a phone", () => {
		// The device profile minus its browser type: Playwright refuses a
		// per-describe browser switch, and the bug is in the page, not the engine.
		const { defaultBrowserType: _engine, ...iPhone } = devices["iPhone 15"];
		test.use(iPhone);

		// #2003 opened the vault in a new tab on Approve, before redirecting the
		// consent tab. On a phone the new tab takes the foreground and the
		// consent tab is suspended, so the redirect never ran: the code was
		// minted and never redeemed (mobile 2/30 on 2026-10-19). Desktop
		// Playwright keeps a background tab running, so the test above stayed
		// green. Approve must hand off in THIS tab and open no other.
		test("approve opens no tab and hands off in the same tab", async ({ page }) => {
			const opened: string[] = [];
			page.context().on("page", (p) => opened.push(p.url()));

			await approveThroughOnboarding(page, (pending as { email: string }).email);

			expect(opened).toEqual([]);
		});
	});
});

/** Sign in mid-authorization, finish onboarding, approve, and land on the callback. */
async function approveThroughOnboarding(page: Page, email: string): Promise<void> {
	const clientId = await registerClient();

	await clerkSignIn(page, email, consentUrl(clientId));

	// 1. Bounced into the wizard rather than shown an Approve button that
	//    would mint an unusable grant.
	await page.waitForURL(/\/onboard/u, { timeout: 20_000 });
	await expect(page.getByRole("button", { name: /^(?:review|approve)$/iu })).toHaveCount(0);

	// 2. The detour can still be refused: the registered redirect gets a
	//    "Stop connecting" control the waiting client will hear.
	await expect(page.getByRole("button", { name: /stop connecting this app/iu })).toBeVisible({
		timeout: 10_000,
	});

	// 3. A connector signup's only step is the terms (SaaS). Accepting
	//    them starts the account on Free and provisions its vault, so
	//    there is no plan, tools, survey or vault step. With billing off
	//    there is no terms step either and the wizard returns at once.
	//    It is not asked how it heard about us: the client is the answer.
	if (new URL(page.url()).pathname === "/onboard/agreement") {
		await expect(page.getByRole("radio")).toHaveCount(0);
		await page.getByLabel(/I have read and agree/iu).click();
		await page.getByRole("button", { name: /^continue$/iu }).click();
	}

	// 4. Returned to the authorization, with the request intact. `state` is
	//    the whole point: an OAuth client rejects a callback whose state
	//    does not match what it sent.
	await page.waitForURL(/\/oauth\/consent/u, { timeout: 25_000 });
	expect(new URL(page.url()).searchParams.get("state")).toBe(STATE);
	expect(new URL(page.url()).searchParams.get("client_id")).toBe(clientId);

	// 5. Approving now yields a code, which is what was impossible before.
	//
	// Matched on PATHNAME, not a substring. The consent page's own URL
	// carries `redirect_uri=...%2Foauth-callback-test`, so a loose regex
	// matches before any navigation happens and the assertions below then
	// read the consent URL's params instead of the callback's.
	// A brand-new account's first app gets the short form: name the vault
	// provisioned at signup, then Approve. No picker, no Review step.
	await expect(page.getByLabel(/name your first vault/iu)).toBeVisible({ timeout: 10_000 });
	await page.getByRole("button", { name: /^approve$/iu }).click();
	await page.waitForURL((url) => new URL(url).pathname === CALLBACK_PATH, {
		timeout: 25_000,
	});

	const callback = new URL(page.url());
	// `error` first: when the grant is refused the callback carries a
	// reason, and reporting that beats "expected truthy, got null".
	expect(callback.searchParams.get("error")).toBeNull();
	expect(callback.searchParams.get("code")).toBeTruthy();
	expect(callback.searchParams.get("state")).toBe(STATE);
}
