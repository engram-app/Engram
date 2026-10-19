import { expect, test } from "@playwright/test";
import { createVault, registerAndLogin, signIn } from "./support/api";

function testEmail(label: string) {
	return `e2e-theme-${Date.now()}-${label}@test.com`;
}

async function registerUser(baseURL: string, email: string): Promise<void> {
	const token = await registerAndLogin(baseURL, email);
	await createVault(baseURL, token, "E2E Vault");
}

test.describe("Dark mode", () => {
	test("account menu hosts the theme picker — Light / Dark / System", async ({ page, baseURL }) => {
		const email = testEmail("menu");
		await registerUser(baseURL!, email);
		await signIn(page, email);
		await expect(page).toHaveURL("/");

		// ThemeToggle now lives inside the rail's account popover (UserMenu).
		// Trigger = avatar button labelled "User menu". The three theme options
		// are radio rows (role=menuitemradio) inside the dropdown.
		const userMenu = page.getByRole("button", { name: "User menu" });
		await expect(page.locator("html")).not.toHaveClass(/dark/u);

		// Open menu → pick Dark
		await userMenu.click();
		const darkRow = page.getByRole("menuitemradio", { name: "Dark" });
		await expect(darkRow).toBeVisible();
		await darkRow.click();
		await expect(page.locator("html")).toHaveClass(/dark/u);

		// Reopen → Dark row is now aria-checked
		await userMenu.click();
		await expect(page.getByRole("menuitemradio", { name: "Dark" })).toHaveAttribute(
			"aria-checked",
			"true",
		);

		// Pick Light → html class drops
		await page.getByRole("menuitemradio", { name: "Light" }).click();
		await expect(page.locator("html")).not.toHaveClass(/dark/u);

		// Pick System; localStorage persists the choice
		await userMenu.click();
		await page.getByRole("menuitemradio", { name: "System" }).click();
		const stored = await page.evaluate(() => window.localStorage.getItem("engram:theme"));
		expect(stored).toBe("system");

		// Esc closes the menu without changing theme (System still active)
		await userMenu.click();
		await expect(page.getByRole("menuitemradio", { name: "System" })).toBeVisible();
		await page.keyboard.press("Escape");
		await expect(page.getByRole("menuitemradio", { name: "System" })).toBeHidden();
	});

	test("System mode tracks prefers-color-scheme", async ({ browser, baseURL }) => {
		const email = testEmail("system");
		await registerUser(baseURL!, email);

		const ctx = await browser.newContext({ colorScheme: "dark" });
		const page = await ctx.newPage();
		await signIn(page, email);
		await expect(page).toHaveURL("/");

		// First-paint check: with empty storage (system) + colorScheme dark, html should have .dark.
		await expect(page.locator("html")).toHaveClass(/dark/u);
		await ctx.close();
	});

	test("FOUC-free: pre-seeded localStorage applies class before React mounts", async ({
		browser,
		baseURL,
	}) => {
		const email = testEmail("fouc");
		await registerUser(baseURL!, email);

		const ctx = await browser.newContext();
		await ctx.addInitScript(() => {
			window.localStorage.setItem("engram:theme", "dark");
		});
		const page = await ctx.newPage();
		await page.goto(`${baseURL!}/sign-in/`);
		// At domcontentloaded the inline boot script has already run.
		await page.waitForLoadState("domcontentloaded");
		await expect(page.locator("html")).toHaveClass(/dark/u);
		await ctx.close();
	});
});
