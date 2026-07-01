import { test, expect } from "@playwright/test";

const TEST_PASSWORD = "E2eTestPass!99";

/** Register a user via API (not browser). Survives worker restarts. */
async function registerUser(baseURL: string, email: string) {
	const res = await fetch(`${baseURL}/api/auth/register`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ email, password: TEST_PASSWORD }),
	});
	if (res.status === 422) return; // already exists (idempotent)
	if (!res.ok) throw new Error(`Register ${email} failed: ${res.status} ${await res.text()}`);

	// Pre-complete onboarding so subsequent UI sign-in lands on the dashboard
	// instead of being bounced to /onboard/vault by OnboardingGate; record a
	// dismissed:tour action and seed a default vault so the dashboard's
	// checklist tour row + CreateFirstVaultModal don't intercept every click.
	const { access_token: token } = await res.json();
	const auth = { "Content-Type": "application/json", Authorization: `Bearer ${token}` };
	const prof = await fetch(`${baseURL}/api/onboarding/profile`, {
		method: "PATCH",
		headers: auth,
		body: JSON.stringify({ uses_obsidian: true, tools: ["claude"] }),
	});
	if (!prof.ok)
		throw new Error(`Onboarding profile PATCH failed: ${prof.status} ${await prof.text()}`);
	const act = await fetch(`${baseURL}/api/onboarding/actions`, {
		method: "POST",
		headers: auth,
		body: JSON.stringify({ action: "dismissed:tour" }),
	});
	if (!act.ok) throw new Error(`Onboarding action POST failed: ${act.status} ${await act.text()}`);
	const vault = await fetch(`${baseURL}/api/vaults`, {
		method: "POST",
		headers: auth,
		body: JSON.stringify({ name: "E2E Vault" }),
	});
	if (!vault.ok) throw new Error(`Vault POST failed: ${vault.status} ${await vault.text()}`);
}

/** Unique email per test — no cross-test dependency. */
function testEmail(label: string) {
	return `e2e-local-${Date.now()}-${label}@test.com`;
}

test.describe("Local auth provider", () => {
	test("redirects unauthenticated users to sign-in", async ({ page }) => {
		await page.goto("/");
		// Wait for auth provider to finish loading before checking redirect
		await page.getByText("Loading...").waitFor({ state: "hidden", timeout: 15_000 });
		await expect(page).toHaveURL(/\/sign-in/);
		await expect(page.getByRole("heading", { name: "Sign in to Engram" })).toBeVisible();
		await expect(page.locator(".cl-signIn")).toHaveCount(0);
	});

	test("register first user → redirects to onboarding", async ({ page }) => {
		const email = testEmail("register");
		await page.goto("/sign-up/");
		await expect(page.getByRole("heading", { name: "Create your account" })).toBeVisible();

		await page.getByLabel("Email").fill(email);
		await page.getByLabel("Password", { exact: true }).fill(TEST_PASSWORD);
		await page.getByLabel("Confirm password").fill(TEST_PASSWORD);
		await page.getByRole("button", { name: "Create account" }).click();

		// OnboardingGate sends fresh accounts through the wizard; tools is the
		// first universal step in self-host mode (billing/agreement auto-pass).
		await expect(page).toHaveURL(/\/onboard\/tools/, { timeout: 10_000 });
	});

	test("sign out → redirects to sign-in", async ({ page, baseURL }) => {
		const email = testEmail("signout");
		await registerUser(baseURL!, email);

		await page.goto("/sign-in/");
		await page.getByLabel("Email").fill(email);
		await page.getByLabel("Password", { exact: true }).fill(TEST_PASSWORD);
		await page.getByRole("button", { name: "Sign in" }).click();
		await expect(page).toHaveURL(/\/$/, { timeout: 10_000 });

		await page.getByLabel("User menu").click();
		await page.getByRole("menuitem", { name: "Sign out" }).click();

		await expect(page).toHaveURL(/\/sign-in/);
	});

	test("sign in with existing credentials → dashboard", async ({ page, baseURL }) => {
		const email = testEmail("signin");
		await registerUser(baseURL!, email);

		await page.goto("/sign-in/");
		await page.getByLabel("Email").fill(email);
		await page.getByLabel("Password", { exact: true }).fill(TEST_PASSWORD);
		await page.getByRole("button", { name: "Sign in" }).click();

		await expect(page).toHaveURL(/\/$/, { timeout: 10_000 });
	});

	test("wrong password shows error", async ({ page, baseURL }) => {
		const email = testEmail("wrongpw");
		await registerUser(baseURL!, email);

		await page.goto("/sign-in/");
		await page.getByLabel("Email").fill(email);
		await page.getByLabel("Password", { exact: true }).fill("WrongPassword!");
		await page.getByRole("button", { name: "Sign in" }).click();

		await expect(page.getByRole("alert")).toBeVisible();
		await expect(page).toHaveURL(/\/sign-in/);
	});

	test("second user registration works", async ({ page }) => {
		const email = testEmail("register2");
		await page.goto("/sign-up/");
		await page.getByLabel("Email").fill(email);
		await page.getByLabel("Password", { exact: true }).fill(TEST_PASSWORD);
		await page.getByLabel("Confirm password").fill(TEST_PASSWORD);
		await page.getByRole("button", { name: "Create account" }).click();

		await expect(page).toHaveURL(/\/onboard\/tools/, { timeout: 10_000 });
	});
});
