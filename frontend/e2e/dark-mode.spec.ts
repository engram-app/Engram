import { expect, test } from "@playwright/test";

const TEST_PASSWORD = "E2eTestPass!99";

async function registerUser(baseURL: string, email: string) {
	const res = await fetch(`${baseURL}/api/auth/register`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ email, password: TEST_PASSWORD }),
	});
	if (res.status === 422) {
		return;
	}
	if (!res.ok) {
		throw new Error(`Register failed: ${res.status} ${await res.text()}`);
	}
	const { access_token: token } = await res.json();
	const auth = { "Content-Type": "application/json", Authorization: `Bearer ${token}` };
	const prof = await fetch(`${baseURL}/api/onboarding/profile`, {
		method: "PATCH",
		headers: auth,
		body: JSON.stringify({ uses_obsidian: true, tools: ["claude"] }),
	});
	if (!prof.ok) {
		throw new Error(`onboarding PATCH failed: ${prof.status} ${await prof.text()}`);
	}
	const act = await fetch(`${baseURL}/api/onboarding/actions`, {
		method: "POST",
		headers: auth,
		body: JSON.stringify({ action: "dismissed:tour" }),
	});
	if (!act.ok) {
		throw new Error(`onboarding action POST failed: ${act.status} ${await act.text()}`);
	}
	const vault = await fetch(`${baseURL}/api/vaults`, {
		method: "POST",
		headers: auth,
		body: JSON.stringify({ name: "E2E Vault" }),
	});
	if (!vault.ok) {
		throw new Error(`vault POST failed: ${vault.status} ${await vault.text()}`);
	}
}

function testEmail(label: string) {
	return `e2e-theme-${Date.now()}-${label}@test.com`;
}

async function signIn(page: import("@playwright/test").Page, email: string) {
	await page.goto("/sign-in/");
	await page.getByLabel("Email").fill(email);
	await page.getByLabel("Password", { exact: true }).fill(TEST_PASSWORD);
	await page.getByRole("button", { name: /sign in/iu }).click();
	await expect(page).toHaveURL("/");
}

it.describe("Dark mode", () => {
	it("account menu hosts the theme picker — Light / Dark / System", async ({ page, baseURL }) => {
		const email = testEmail("menu");
		await registerUser(baseURL!, email);
		await signIn(page, email);

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

	it("System mode tracks prefers-color-scheme", async ({ browser, baseURL }) => {
		const email = testEmail("system");
		await registerUser(baseURL!, email);

		const ctx = await browser.newContext({ colorScheme: "dark" });
		const page = await ctx.newPage();
		await signIn(page, email);

		// First-paint check: with empty storage (system) + colorScheme dark, html should have .dark.
		await expect(page.locator("html")).toHaveClass(/dark/u);
		await ctx.close();
	});

	it("FOUC-free: pre-seeded localStorage applies class before React mounts", async ({
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
