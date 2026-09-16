import { setupClerkTestingToken } from "@clerk/testing/playwright";
import { expect, test } from "@playwright/test";
import { clerkSignIn, loadAuthState } from "./clerk-helpers";

/**
 * An MCP-first signup completes onboarding and resumes the authorization.
 *
 * A user can reach `/oauth/consent` having just signed up inside the OAuth
 * flow itself, with no terms accepted, no plan and no vault. Approving in that
 * state used to mint a grant the vault gate refused on every subsequent call —
 * valid tokens, permanent 403, nothing in the response saying what to do
 * (#1666). One real user burned five hours against that wall.
 *
 * This is the only test in either suite that is an UN-ONBOARDED user. Every
 * other fixture — this file's global-setup, e2e/helpers/oauth.py,
 * e2e/helpers/clerk_auth.py — pre-completes onboarding before the first
 * assertion, which is precisely why the harness could never reach the broken
 * state and the bug shipped.
 *
 * It is also the only place the SPA talks to the real backend across this
 * path. Every unit test mocks `../api/oauth`, so nothing else verifies that
 * `/api/oauth/clients/:id?redirect_uri=` actually returns `slug` in the shape
 * the consent page reads, or that the browser's pre-answer POST lands and
 * makes `next_step` skip `tools`.
 */

const CLERK_BACKEND_PORT = process.env.PW_CLERK_BACKEND_PORT ?? "4001";
const CLERK_VITE_PORT = process.env.PW_CLERK_VITE_PORT ?? "5174";

// Loopback on the SPA's own origin, so approving cannot navigate the browser
// off-box. The page 404s; the assertion is on the URL, which is where the
// authorization code is delivered.
const REDIRECT_URI = `http://localhost:${CLERK_VITE_PORT}/oauth-callback-test`;

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

	test.skip(
		() => state.skipped || !state.pending_email,
		"No un-onboarded Clerk user provisioned — needs E2E_CLERK_SECRET_KEY",
	);

	test.beforeEach(async ({ page }) => {
		await setupClerkTestingToken({ page });
	});

	test("consent → wizard → back to consent → approve", async ({ page }) => {
		const clientId = await registerClient();

		// The un-onboarded user, NOT the shared pre-onboarded one.
		await clerkSignIn(page, state.pending_email as string, consentUrl(clientId));

		// 1. Bounced into the wizard rather than shown an Approve button that
		//    would mint an unusable grant.
		await page.waitForURL(/\/onboard/u, { timeout: 20_000 });
		await expect(page.getByRole("button", { name: /approve/iu })).toHaveCount(0);

		// 2. The detour names the app that is waiting. Dumping someone into an
		//    unexplained signup is the phishing-shaped UX the OAuth guidance
		//    warns about.
		await expect(page.getByText(new RegExp(CLIENT_NAME, "iu")).first()).toBeVisible({
			timeout: 10_000,
		});

		// 3. Terms.
		await page.waitForURL(/\/onboard\/agreement/u, { timeout: 15_000 });
		await page.getByLabel(/I have read and agree/iu).click();
		await page.getByRole("button", { name: /^continue$/iu }).click();

		// 4. Plan.
		await page.waitForURL(/\/onboard\/billing/u, { timeout: 20_000 });
		await page.getByRole("button", { name: /continue with free/iu }).click();

		// 5. Straight to the vault step. If the tool question had NOT been
		//    pre-answered from the connecting client, this lands on
		//    /onboard/tools and the wait below is what fails.
		await page.waitForURL(/\/onboard\/vault/u, { timeout: 20_000 });

		// 6. First vault.
		await page.getByRole("button", { name: /starting fresh/iu }).click();
		await page.getByLabel(/vault name/iu).fill("E2E Consent Vault");
		await page.getByRole("button", { name: /create vault & continue/iu }).click();

		// 7. Returned to the authorization, with the request intact. `state` is
		//    the whole point: an OAuth client rejects a callback whose state
		//    does not match what it sent.
		await page.waitForURL(/\/oauth\/consent/u, { timeout: 25_000 });
		expect(new URL(page.url()).searchParams.get("state")).toBe(STATE);
		expect(new URL(page.url()).searchParams.get("client_id")).toBe(clientId);

		// 8. Approving now yields a code, which is what was impossible before.
		await page.getByRole("button", { name: /approve/iu }).click();
		await page.waitForURL(/oauth-callback-test/u, { timeout: 25_000 });

		const callback = new URL(page.url());
		expect(callback.searchParams.get("code")).toBeTruthy();
		expect(callback.searchParams.get("state")).toBe(STATE);
		expect(callback.searchParams.get("error")).toBeNull();
	});
});
