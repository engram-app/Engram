import { expect, test } from "@playwright/test";
import { deleteAccount, PASS } from "./support/api";
import { BROWSER_LOCALES, checkStep } from "./support/i18n-leaks";
import { walkOnboarding } from "./support/i18n-onboarding";

// Self-host first run in each locale: sign-up, then the wizard (support/i18n-onboarding.ts:
// tools, vault with both source cards, then "starting fresh"), the dashboard it lands
// on, and Settings > Account. Every step
// asserts `<html lang>`, fails on untranslated wrapped strings, reports suspected
// unwrapped English (non-Latin locales) and attaches a full-page screenshot.
//
// Self-host chain: tools -> vault (agreement and billing auto-pass), see
// local-auth.spec.ts. Registers one user per locale, deleted afterwards through
// DELETE /api/me. Do NOT point this at a persistent shared database.

for (const { tag, code } of BROWSER_LOCALES) {
	test.describe(`self-host onboarding in ${code}`, () => {
		test.use({ locale: tag });

		let email: string | null = null;

		test.afterEach(async ({ baseURL }) => {
			if (email) {
				await deleteAccount(baseURL ?? "", email);
				email = null;
			}
		});

		test("every step is translated", async ({ page }, testInfo) => {
			// Registration + wizard + dashboard: well past the 30s default under load.
			test.setTimeout(120_000);
			email = `i18n-e2e-${Date.now()}-${code.toLowerCase()}@test.com`;

			await page.goto("/sign-up/");
			await expect(page.locator('input[type="email"]')).toBeVisible();
			await checkStep(page, testInfo, code, "sign-up");

			await page.locator('input[type="email"]').fill(email);
			await page.locator('input[type="password"]').first().fill(PASS);
			await page.locator('input[type="password"]').last().fill(PASS);
			await page.locator("form button[type='submit']").click();

			await expect(page).toHaveURL(/\/onboard\/tools/u, { timeout: 15_000 });
			// Self-host chain starts at tools (agreement and billing auto-pass).
			await expect(page).toHaveURL(/\/onboard\/tools/u, { timeout: 15_000 });
			await walkOnboarding(page, testInfo, code);
		});
	});
}
