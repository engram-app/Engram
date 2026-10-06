import { expect, test } from "@playwright/test";
import { deleteAccount, PASS } from "./support/api";
import { BROWSER_LOCALES, checkStep, translationOf } from "./support/i18n-leaks";

// Self-host first run in each locale: sign-up, tools, vault (both source cards, then
// "starting fresh"), the dashboard it lands on, and Settings > Account. Every step
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
			const t = (key: string) => translationOf(code, key);
			email = `i18n-e2e-${Date.now()}-${code.toLowerCase()}@test.com`;

			await page.goto("/sign-up/");
			await expect(page.locator('input[type="email"]')).toBeVisible();
			await checkStep(page, testInfo, code, "sign-up");

			await page.locator('input[type="email"]').fill(email);
			await page.locator('input[type="password"]').first().fill(PASS);
			await page.locator('input[type="password"]').last().fill(PASS);
			await page.locator("form button[type='submit']").click();

			await expect(page).toHaveURL(/\/onboard\/tools/u, { timeout: 15_000 });
			await expect(
				page.getByRole("heading", { name: t("Which AI tools do you use?") }),
			).toBeVisible();
			await checkStep(page, testInfo, code, "tools");

			// The opt-out is the last checkbox, after both tool columns.
			await page.getByRole("checkbox").last().check();
			await checkStep(page, testInfo, code, "tools-none-selected");
			await page.getByRole("button", { name: t("Continue"), exact: true }).click();

			await expect(page).toHaveURL(/\/onboard\/vault/u, { timeout: 15_000 });
			await expect(
				page.getByRole("heading", { name: t("Let's get your notes in.") }),
			).toBeVisible();
			await checkStep(page, testInfo, code, "vault");

			await page.getByRole("button", { name: t("I already use Obsidian") }).click();
			await expect(
				page.getByRole("heading", { name: t("Install the Engram Vault Sync plugin") }),
			).toBeVisible();
			await checkStep(page, testInfo, code, "vault-obsidian");

			await page.getByRole("button", { name: t("I'm starting fresh") }).click();
			await expect(page.getByRole("heading", { name: t("Name your first vault") })).toBeVisible();
			await checkStep(page, testInfo, code, "vault-fresh");

			await page.getByRole("button", { name: t("Create vault & continue") }).click();
			await expect(page.getByRole("navigation", { name: t("App navigation") })).toBeVisible({
				timeout: 20_000,
			});
			expect(new URL(page.url()).pathname.startsWith("/onboard")).toBe(false);
			await checkStep(page, testInfo, code, "dashboard");

			await page.goto("/#settings/account");
			await expect(page.getByRole("combobox", { name: t("Language") })).toBeVisible();
			await checkStep(page, testInfo, code, "settings-account");
		});
	});
}
