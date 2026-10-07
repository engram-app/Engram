import { setupClerkTestingToken } from "@clerk/testing/playwright";
import { expect, test } from "@playwright/test";
import type { Locale } from "../src/i18n/locales";
import { clerkLocalizationLoaders } from "../src/i18n/vendor-locales";
import { clerkSignIn, loadAuthState } from "./clerk-helpers";
import { BROWSER_LOCALES, checkStep } from "./support/i18n-leaks";
import { walkOnboarding } from "./support/i18n-onboarding";

// SaaS-shape first run in each locale (project `clerk`): Clerk's sign-up screen, then
// the wizard as the backend serves it (agreement, billing, tools, vault), the
// dashboard and Settings > Account. Same checks as i18n-onboarding.spec.ts, with
// Clerk's own subtree (.cl-rootBox) excluded from the leak scan: Clerk localizes it.
// Instead the Clerk screen's title must equal @clerk/localizations' string for the
// locale, proving ClerkProvider followed the app language.
//
// Needs E2E_CLERK_SECRET_KEY like the other clerk specs. Users are created through
// Clerk's Backend API (no UI sign-up: it needs an e-mail code), the way
// oauth-consent-onboarding.spec.ts does, and deleted afterwards. The e2e-browser-
// prefix keeps them inside the Clerk orphan reaper and db-cleanup patterns.

const CLERK_API = "https://api.clerk.com/v1";
const SECRET_KEY = process.env.E2E_CLERK_SECRET_KEY ?? "";

async function createUnonboardedUser(code: string): Promise<{ email: string; id: string }> {
	const ts = Date.now();
	const email = `e2e-browser-i18n-e2e-${ts}-${code.toLowerCase()}@test.com`;
	const resp = await fetch(`${CLERK_API}/users`, {
		method: "POST",
		headers: { Authorization: `Bearer ${SECRET_KEY}`, "Content-Type": "application/json" },
		body: JSON.stringify({
			email_address: [email],
			username: `e2e-i18n-${ts}-${code.toLowerCase()}`,
			password: `pw-${ts}-${Math.random().toString(36).slice(2)}`,
			skip_password_checks: true,
		}),
	});
	if (!resp.ok) {
		throw new Error(`Clerk user creation failed: ${resp.status} ${await resp.text()}`);
	}
	const user: { id: string } = await resp.json();
	return { email, id: user.id };
}

async function clerkSignUpTitle(code: Locale): Promise<string> {
	const localization = await clerkLocalizationLoaders[code]?.();
	const title = localization?.signUp?.start?.title;
	if (!title) {
		throw new Error(`@clerk/localizations has no signUp.start.title for ${code}`);
	}
	return title;
}

for (const { tag, code } of BROWSER_LOCALES) {
	test.describe(`SaaS onboarding in ${code}`, () => {
		const state = loadAuthState();
		const skip = state.skipped || !SECRET_KEY;
		let user: { email: string; id: string } | null = null;

		test.skip(() => skip, "E2E_CLERK_SECRET_KEY not set — Clerk browser tests skipped");
		test.use({ locale: tag });

		test.beforeEach(async ({ page }) => {
			await setupClerkTestingToken({ page });
		});

		test.afterEach(async () => {
			if (!user) {
				return;
			}
			await fetch(`${CLERK_API}/users/${user.id}`, {
				method: "DELETE",
				headers: { Authorization: `Bearer ${SECRET_KEY}` },
			})
				.then((resp) => {
					if (!resp.ok) {
						console.warn(`clerk teardown failed for ${user?.id}: ${resp.status}`);
					}
				})
				.catch((err) => console.warn(`clerk teardown errored for ${user?.id}: ${String(err)}`));
			user = null;
		});

		test("every step is translated", async ({ page }, testInfo) => {
			// Clerk sign-in, Paddle-backed billing screen and the wizard: slow under load.
			test.setTimeout(180_000);

			await page.goto("/sign-up/");
			const clerkRoot = page.locator(".cl-rootBox");
			await expect(clerkRoot).toBeVisible({ timeout: 20_000 });
			await expect(clerkRoot.getByText(await clerkSignUpTitle(code)).first()).toBeVisible();
			await checkStep(page, testInfo, code, "clerk-sign-up", { skipClerk: true });

			user = await createUnonboardedUser(code);
			await clerkSignIn(page, user.email);
			await walkOnboarding(page, testInfo, code, { skipClerk: true });
		});
	});
}
