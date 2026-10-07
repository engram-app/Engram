import { expect, type Page, test } from "@playwright/test";
import { LOCALE_NAMES } from "../src/i18n/locales";
import { createVault, deleteAccount, PASS, registerAndLogin } from "./support/api";
import { BROWSER_LOCALES, translationOf } from "./support/i18n-leaks";

// Language selection in a real browser: stored pick, then navigator.languages, then
// English, and the in-app picker. Catalog-derived strings (never hard-coded per
// locale) prove the catalog on screen is the one `<html lang>` claims.
//
// The picker test registers a user; its title carries "[registers user]" so it can
// be excluded with --grep-invert when the backend's database is not disposable.

const SIGN_IN_HEADING = "Sign in to Engram";

async function expectLanguage(page: Page, code: string): Promise<void> {
	await expect(page.locator("html")).toHaveAttribute("lang", code);
}

async function expectSignInHeading(page: Page, code: string): Promise<void> {
	const name = code === "en" ? SIGN_IN_HEADING : translationOf(code, SIGN_IN_HEADING);
	await expect(page.getByRole("heading", { name })).toBeVisible();
}

for (const { tag, code } of BROWSER_LOCALES) {
	test.describe(`browser locale ${tag}`, () => {
		test.use({ locale: tag });

		test(`sign-in page renders ${code}`, async ({ page }) => {
			await page.goto("/sign-in/");
			await expectLanguage(page, code);
			await expectSignInHeading(page, code);
		});
	});
}

const FALLBACKS = [
	{ tag: "en-GB", code: "en" },
	{ tag: "zh-HK", code: "zh-TW" },
	{ tag: "pt-PT", code: "pt-BR" },
	{ tag: "nl-NL", code: "en" },
] as const;

for (const { tag, code } of FALLBACKS) {
	test.describe(`fallback ${tag}`, () => {
		test.use({ locale: tag });

		test(`resolves to ${code}`, async ({ page }) => {
			await page.goto("/sign-in/");
			await expectLanguage(page, code);
			await expectSignInHeading(page, code);
		});
	});
}

test.describe("stored pick beats the browser", () => {
	test.use({ locale: "de-DE" });

	test("engram:locale=ja under a German browser renders Japanese", async ({ page }) => {
		await page.addInitScript(() => window.localStorage.setItem("engram:locale", "ja"));
		await page.goto("/sign-in/");
		await expectLanguage(page, "ja");
		await expectSignInHeading(page, "ja");
	});

	test("an unknown stored value is ignored", async ({ page }) => {
		await page.addInitScript(() => window.localStorage.setItem("engram:locale", "xx"));
		await page.goto("/sign-in/");
		await expectLanguage(page, "de");
	});
});

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

		await page.goto("/sign-in/");
		await page.getByLabel("Email").fill(email);
		await page.getByLabel("Password", { exact: true }).fill(PASS);
		await page.getByRole("button", { name: "Sign in" }).click();
		// `/\/$/` would also match /sign-in/, so wait for the page to leave it.
		await expect(page).not.toHaveURL(/\/sign-in/u, { timeout: 15_000 });
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
