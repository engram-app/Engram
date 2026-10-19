import { clerk, setupClerkTestingToken } from "@clerk/testing/playwright";
import { expect, type Page, test } from "@playwright/test";
import { loadAuthState } from "./clerk-helpers";

const SIGN_IN = '[data-clerk-component="SignIn"]';
// The header uses a custom avatar dropdown (UserMenu), not Clerk's <UserButton>.
const USER_MENU = { role: "button" as const, name: "User menu" };

/**
 * Sign in via Clerk Backend API ticket — bypasses form + bot detection entirely.
 * Creates a sign-in token server-side, then uses it client-side via strategy: 'ticket'.
 * Requires CLERK_SECRET_KEY env var (set in global-setup).
 *
 * No retry on "No user found" here — global-setup probes BOTH endpoints
 * @clerk/testing's signIn hits (GET /users?email_address for email→id
 * resolution + POST /sign_in_tokens for token creation) before writing
 * .auth-state.json, so any "No user found" here indicates a real problem
 * (user deleted mid-run, instance swap, etc.) and should surface
 * immediately. See #193 + global-setup.ts {waitUntilEmailResolvable,
 * waitUntilSignInReady}.
 */
async function clerkSignIn(page: Page, email: string) {
	// Navigate first so Clerk JS SDK loads on the page
	await page.goto("/sign-in/");
	await clerk.signIn({ page, emailAddress: email });
	await page.goto("/");
	await expect(page).toHaveURL(/\/$/u, { timeout: 15_000 });
}

test.describe("Clerk auth provider", () => {
	const state = loadAuthState();

	test.skip(() => state.skipped, "E2E_CLERK_SECRET_KEY not set — skipping Clerk browser tests");

	// Bypass Clerk's bot detection — intercepts Clerk Frontend API requests
	// and injects testing token + captcha bypass via @clerk/testing
	test.beforeEach(async ({ page }) => {
		await setupClerkTestingToken({ page });
	});

	test("redirects unauthenticated users to sign-in with Clerk UI", async ({ page }) => {
		await page.goto("/");
		// Wait for auth provider to finish loading before checking redirect
		await page.getByText("Loading...").waitFor({ state: "hidden", timeout: 15_000 });
		await expect(page).toHaveURL(/\/sign-in/u);
		await expect(page.locator(SIGN_IN)).toBeVisible({ timeout: 15_000 });
		await expect(page.locator("h1.cl-headerTitle")).toContainText("Sign in");
	});

	test("sign out via Clerk → redirects", async ({ page }) => {
		await clerkSignIn(page, state.email);

		await page.getByRole(USER_MENU.role, { name: USER_MENU.name }).click();
		await page.getByRole("menuitem", { name: /sign out/iu }).click();

		await expect(page).toHaveURL(/\/sign-in/u, { timeout: 10_000 });
	});
});
