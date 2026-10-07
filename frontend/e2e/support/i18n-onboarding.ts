import { expect, type Page, type TestInfo } from "@playwright/test";
import { checkStep, type StepOptions, translationOf } from "./i18n-leaks";

// The onboarding wizard in one locale, shared by the self-host and SaaS specs. It
// follows whichever steps the backend serves (SaaS: agreement, billing, tools,
// vault; self-host: tools, vault) and ends on the dashboard and Settings > Account,
// running the leak checks at every one. Locators go by role and position, never by
// English text, so the walk keeps working as strings get translated.

const MAX_STEPS = 6;

async function leaveStep(page: Page, from: string): Promise<void> {
	await page.waitForURL((url) => url.pathname !== from, { timeout: 20_000 });
}

async function agreementStep(
	page: Page,
	testInfo: TestInfo,
	code: string,
	options: StepOptions,
): Promise<void> {
	await expect(
		page.getByRole("heading", { name: translationOf(code, "Review the Terms") }),
	).toBeVisible();
	// The Continue button stays disabled until the terms text has loaded.
	const agree = page.getByRole("checkbox");
	await expect(agree).toBeVisible({ timeout: 20_000 });
	await checkStep(page, testInfo, code, "agreement", options);
	await agree.click();
	await page.getByRole("button", { name: translationOf(code, "Continue"), exact: true }).click();
}

async function billingStep(
	page: Page,
	testInfo: TestInfo,
	code: string,
	options: StepOptions,
): Promise<void> {
	await expect(
		page.getByRole("heading", { name: translationOf(code, "Choose your plan") }),
	).toBeVisible();
	await checkStep(page, testInfo, code, "billing", options);
	await page.getByRole("button", { name: translationOf(code, "Continue with Free →") }).click();
}

async function toolsStep(
	page: Page,
	testInfo: TestInfo,
	code: string,
	options: StepOptions,
): Promise<void> {
	await expect(
		page.getByRole("heading", { name: translationOf(code, "Which AI tools do you use?") }),
	).toBeVisible();
	await checkStep(page, testInfo, code, "tools", options);

	// The opt-out is the last checkbox, after both tool columns.
	await page.getByRole("checkbox").last().check();
	await checkStep(page, testInfo, code, "tools-none-selected", options);
	await page.getByRole("button", { name: translationOf(code, "Continue"), exact: true }).click();
}

async function vaultStep(
	page: Page,
	testInfo: TestInfo,
	code: string,
	options: StepOptions,
): Promise<void> {
	const t = (key: string) => translationOf(code, key);
	await expect(page.getByRole("heading", { name: t("Let's get your notes in.") })).toBeVisible();
	await checkStep(page, testInfo, code, "vault", options);

	await page.getByRole("button", { name: t("I already use Obsidian") }).click();
	await expect(
		page.getByRole("heading", { name: t("Install the Engram Vault Sync plugin") }),
	).toBeVisible();
	await checkStep(page, testInfo, code, "vault-obsidian", options);

	await page.getByRole("button", { name: t("I'm starting fresh") }).click();
	await expect(page.getByRole("heading", { name: t("Name your first vault") })).toBeVisible();
	await checkStep(page, testInfo, code, "vault-fresh", options);

	await page.getByRole("button", { name: t("Create vault & continue") }).click();
}

// Starts anywhere under /onboard/ and ends on Settings > Account.
export async function walkOnboarding(
	page: Page,
	testInfo: TestInfo,
	code: string,
	options: StepOptions = {},
): Promise<void> {
	await page.waitForURL(/\/onboard\//u, { timeout: 30_000 });
	for (let i = 0; i < MAX_STEPS && new URL(page.url()).pathname.startsWith("/onboard"); i++) {
		const path = new URL(page.url()).pathname;
		const step = path.split("/").pop();
		if (step === "agreement") {
			await agreementStep(page, testInfo, code, options);
		} else if (step === "billing") {
			await billingStep(page, testInfo, code, options);
		} else if (step === "tools") {
			await toolsStep(page, testInfo, code, options);
		} else if (step === "vault") {
			await vaultStep(page, testInfo, code, options);
		} else {
			throw new Error(`unexpected onboarding step at ${path}`);
		}
		await leaveStep(page, path);
	}

	await expect(
		page.getByRole("navigation", { name: translationOf(code, "App navigation") }),
	).toBeVisible({
		timeout: 25_000,
	});
	expect(new URL(page.url()).pathname.startsWith("/onboard")).toBe(false);
	await checkStep(page, testInfo, code, "dashboard", options);

	await page.goto("/#settings/account");
	await expect(page.getByRole("combobox", { name: translationOf(code, "Language") })).toBeVisible();
	await checkStep(page, testInfo, code, "settings-account", options);
}
