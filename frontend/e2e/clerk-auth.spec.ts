import { setupClerkTestingToken } from "@clerk/testing/playwright";
import { expect, test } from "@playwright/test";
import { clerkSignIn, loadAuthState } from "./clerk-helpers";

const SIGN_IN = '[data-clerk-component="SignIn"]';
// The header uses a custom avatar dropdown (UserMenu), not Clerk's <UserButton>.
const USER_MENU = { role: "button" as const, name: "User menu" };

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
		await expect(page).toHaveURL(/\/$/u, { timeout: 15_000 });

		await page.getByRole(USER_MENU.role, { name: USER_MENU.name }).click();
		await page.getByRole("menuitem", { name: /sign out/iu }).click();

		await expect(page).toHaveURL(/\/sign-in/u, { timeout: 10_000 });
	});
});
