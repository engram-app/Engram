import { expect, type Page, test } from "@playwright/test";
import { LOCALE_NAMES } from "../src/i18n/locales";
import { createVault, deleteAccount, registerAndLogin, signIn } from "./support/api";
import { translationOf } from "./support/i18n-leaks";

// The in-app language picker in a real browser. Detection order (stored pick,
// then navigator.languages, then English) is unit-tested in i18n/locales.test.ts,
// i18n/storage.test.ts and i18n/locale-provider.test.tsx; every catalog loading
// in a real browser is covered by i18n-onboarding.spec.ts. Catalog-derived
// strings (never hard-coded per locale) prove the catalog on screen is the one
// `<html lang>` claims.
//
// The picker test registers a user; its title carries "[registers user]" so it can
// be excluded with --grep-invert when the backend's database is not disposable.

async function expectLanguage(page: Page, code: string): Promise<void> {
	await expect(page.locator("html")).toHaveAttribute("lang", code);
}

test.describe("language picker", () => {
	let pickerEmail: string | null = null;

	test.afterEach(async ({ baseURL }) => {
		if (pickerEmail) {
			await deleteAccount(baseURL ?? "", pickerEmail);
			pickerEmail = null;
		}
	});

	test("[registers user] Settings > Account switches live and the pick survives a reload", async ({
		page,
		baseURL,
	}) => {
		const email = `i18n-e2e-${Date.now()}-picker@test.com`;
		pickerEmail = email;
		const token = await registerAndLogin(baseURL ?? "", email);
		await createVault(baseURL ?? "", token, "I18n Picker Vault");

		await signIn(page, email);
		await expectLanguage(page, "en");

		await page.goto("/#settings/account");
		await page.getByRole("combobox", { name: "Language" }).click();
		await page.getByRole("option", { name: LOCALE_NAMES.de }).click();

		// No reload: the same document switches language and text together.
		await expectLanguage(page, "de");
		await expect(
			page.getByRole("combobox", { name: translationOf("de", "Language") }),
		).toBeVisible();
		await expect(
			page.getByText(translationOf("de", "Choose the language Engram uses on this device.")),
		).toBeVisible();

		await page.reload();
		await expectLanguage(page, "de");
		expect(await page.evaluate(() => window.localStorage.getItem("engram:locale"))).toBe("de");

		await page.getByRole("combobox", { name: translationOf("de", "Language") }).click();
		await page.getByRole("option", { name: LOCALE_NAMES.ja }).click();
		await expectLanguage(page, "ja");
		await expect(
			page.getByText(translationOf("ja", "Choose the language Engram uses on this device.")),
		).toBeVisible();
	});
});
