import { setupClerkTestingToken } from "@clerk/testing/playwright";
import { expect, type Page, test } from "@playwright/test";
import {
	API_URL,
	APP_URL,
	clerkSignIn,
	completeWebOnboarding,
	createUnonboardedUser,
	deleteClerkUser,
	loadAuthState,
	spaApiHeaders,
} from "./clerk-helpers";

/**
 * First-run experience after the wizard: the recovery vault modal, the setup
 * checklist and the plugin device link. Every test gets its own fresh user and
 * walks the real wizard, so none depends on state a prior run left behind.
 */

const firstVaultHeading = (page: Page) => page.getByRole("heading", { name: /first vault/iu });

async function onboardedUser(page: Page, vaultName: string): Promise<void> {
	await clerkSignIn(page, (pending as { email: string }).email, "/");
	await completeWebOnboarding(page, vaultName);
}

// The "create your first vault" modal only appears for a finished account that
// has zero vaults, so reach it the way a real user does: delete the last one.
async function deleteOnlyVaultAndReload(page: Page): Promise<void> {
	const headers = await spaApiHeaders(page);
	const vaultId = headers["X-Vault-ID"];
	expect(vaultId, "wizard should have set an active vault").toBeTruthy();
	const res = await page.request.delete(`${API_URL}/api/vaults/${vaultId}`, { headers });
	expect(res.ok(), `vault delete failed: ${res.status()}`).toBe(true);
	await page.reload();
}

async function createVaultViaModal(page: Page, name: string): Promise<void> {
	await expect(firstVaultHeading(page)).toBeVisible({ timeout: 15_000 });
	await page.getByLabel("Vault name").fill(name);
	await page.getByRole("button", { name: /create vault/iu }).click();
	await expect(firstVaultHeading(page)).toBeHidden({ timeout: 10_000 });
}

async function expectChecklist(page: Page): Promise<void> {
	// The widget defaults to open ("Finish setup"); if the user dismissed every
	// actionable row the closed-state pill is shown instead.
	const openHeading = page.getByRole("heading", { name: /finish setup/iu });
	const closedPill = page.getByLabel(/open setup checklist/iu);
	await expect(openHeading.or(closedPill).first()).toBeVisible({ timeout: 10_000 });
}

let pending: { email: string; id: string } | null = null;

test.describe("FTUX happy path", () => {
	// Clerk sign-in alone may retry for 30s; the 30s global default cannot ride that out.
	test.setTimeout(90_000);

	const skip = loadAuthState().skipped || !process.env.E2E_CLERK_SECRET_KEY;

	test.skip(() => skip, "E2E_CLERK_SECRET_KEY not set — skipping Clerk FTUX test");

	test.beforeEach(async ({ page }) => {
		pending = await createUnonboardedUser("e2e-browser-ftux");
		await setupClerkTestingToken({ page });
	});

	test.afterEach(async () => {
		if (pending) {
			await deleteClerkUser(pending.id);
			pending = null;
		}
	});

	test("create-vault modal → checklist", async ({ page }) => {
		await onboardedUser(page, "My Vault");
		await deleteOnlyVaultAndReload(page);
		await createVaultViaModal(page, "My Vault");
		await expectChecklist(page);
	});

	test("checklist widget mounts on the dashboard after vault creation", async ({ page }) => {
		await onboardedUser(page, "Skip-Test Vault");
		await expectChecklist(page);
	});

	test("vault modal cannot be dismissed by ESC, click-outside, or close button", async ({
		page,
	}) => {
		await onboardedUser(page, "Modal Vault");
		await deleteOnlyVaultAndReload(page);
		await expect(firstVaultHeading(page)).toBeVisible({ timeout: 15_000 });

		await page.keyboard.press("Escape");
		await expect(firstVaultHeading(page)).toBeVisible();

		await page.mouse.click(10, 10);
		await expect(firstVaultHeading(page)).toBeVisible();

		// No close button visible on this dialog.
		await expect(page.getByRole("button", { name: /close/iu })).toHaveCount(0);
	});

	test("completed flow does not re-fire modals after reload", async ({ page }) => {
		await onboardedUser(page, "Persist Vault");
		await deleteOnlyVaultAndReload(page);
		await createVaultViaModal(page, "Persist Vault Again");

		await page.reload();
		await expect(page.getByRole("navigation", { name: "App navigation" })).toBeVisible({
			timeout: 25_000,
		});
		await expect(firstVaultHeading(page)).toHaveCount(0);
	});

	test("completing device-link flow ticks the plugin checklist item", async ({ page }) => {
		await onboardedUser(page, "Plugin Vault");

		// The checklist only lists the plugin for people who said they use Obsidian,
		// which the wizard's "starting fresh" branch records as false.
		const headers = await spaApiHeaders(page);
		const profile = await page.request.patch(`${API_URL}/api/onboarding/profile`, {
			headers,
			data: { uses_obsidian: true },
		});
		expect(profile.ok(), `profile patch failed: ${profile.status()}`).toBe(true);

		// Before linking, the row must be there and unticked, or the tick below
		// would prove nothing about the link.
		const row = page.getByRole("listitem").filter({ hasText: "Install the Obsidian plugin" });
		await page.goto(`${APP_URL}/`);
		await expect(row).toContainText("☐", { timeout: 15_000 });
		await expect(row).not.toContainText("☑");

		// What the plugin does: ask for a code, show it, poll for the exchange.
		const startRes = await page.request.post(`${API_URL}/api/auth/device`, {
			data: { client_id: "e2e-plugin", vault_name: "Plugin Vault", device_name: "e2e-laptop" },
		});
		expect(startRes.ok(), `device start failed: ${startRes.status()}`).toBe(true);
		const flow = (await startRes.json()) as { device_code: string; user_code: string };

		// The user approves it on /link, an explicit Sync click.
		await page.goto(`${APP_URL}/link?code=${flow.user_code}`);
		await page.getByRole("button", { name: "Sync", exact: true }).click();
		await expect(page.getByText(/your vault is linked/iu)).toBeVisible({ timeout: 15_000 });

		const tokenRes = await page.request.post(`${API_URL}/api/auth/device/token`, {
			data: { device_code: flow.device_code },
		});
		expect(tokenRes.ok(), `device token exchange failed: ${tokenRes.status()}`).toBe(true);

		await page.goto(`${APP_URL}/`);
		await expect(row).toContainText("☑", { timeout: 15_000 });
	});

	test("user with existing vault sees no vault modal", async ({ page }) => {
		await onboardedUser(page, "Backfilled Vault");

		await page.reload();
		await expect(page.getByRole("navigation", { name: "App navigation" })).toBeVisible({
			timeout: 25_000,
		});
		await expect(firstVaultHeading(page)).toHaveCount(0);
	});
});
