import { expect, test } from "@playwright/test";
import { createVault, deleteAccount, PASS, registerAndLogin } from "./support/api";

/**
 * The /link page: what the Obsidian plugin's link code leads to. Self-host
 * (local auth) so the whole flow is the real SPA against the real backend.
 *
 * Every test makes its own user and deletes it, so nothing depends on test order
 * or on the instance already holding vaults.
 */

interface Started {
	device_code: string;
	user_code: string;
}

async function startDeviceFlow(
	baseURL: string,
	hints: { vault_name?: string; device_name?: string },
): Promise<Started> {
	const res = await fetch(`${baseURL}/api/auth/device`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ client_id: "e2e-plugin", ...hints }),
	});
	if (!res.ok) {
		throw new Error(`device start failed: ${res.status} ${await res.text()}`);
	}
	return (await res.json()) as Started;
}

async function exchangeDeviceCode(baseURL: string, deviceCode: string): Promise<void> {
	const res = await fetch(`${baseURL}/api/auth/device/token`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ device_code: deviceCode }),
	});
	if (!res.ok) {
		throw new Error(`device token exchange failed: ${res.status} ${await res.text()}`);
	}
}

async function obsidianConnections(
	baseURL: string,
	token: string,
): Promise<Array<{ kind: string; label: string | null; name: string }>> {
	const res = await fetch(`${baseURL}/api/connections`, {
		headers: { Authorization: `Bearer ${token}` },
	});
	if (!res.ok) {
		throw new Error(`connections failed: ${res.status} ${await res.text()}`);
	}
	const body = (await res.json()) as unknown;
	const rows = (
		Array.isArray(body) ? body : (body as { connections: unknown[] }).connections
	) as Array<{
		kind: string;
		label: string | null;
		name: string;
	}>;
	return rows.filter((r) => r.kind === "obsidian");
}

async function listVaultNames(baseURL: string, token: string): Promise<string[]> {
	const res = await fetch(`${baseURL}/api/vaults`, {
		headers: { Authorization: `Bearer ${token}` },
	});
	const { vaults } = (await res.json()) as { vaults: Array<{ name: string }> };
	return vaults.map((v) => v.name);
}

async function signInAndOpenLink(
	page: import("@playwright/test").Page,
	email: string,
	userCode: string,
): Promise<void> {
	await page.goto("/sign-in/");
	await page.getByLabel("Email").fill(email);
	await page.getByLabel("Password", { exact: true }).fill(PASS);
	await page.getByRole("button", { name: /sign in/iu }).click();
	await expect(page).not.toHaveURL(/\/sign-in/u, { timeout: 15_000 });
	await page.goto(`/link?code=${userCode}`);
	await expect(page.getByRole("heading", { name: "Choose a vault to sync" })).toBeVisible({
		timeout: 15_000,
	});
}

const email = (label: string) => `e2e-link-${Date.now()}-${label}@test.com`;

test.describe("/link vault picker", () => {
	test("suggests the vault matching the plugin's name and links with the typed connection name", async ({
		page,
		baseURL,
	}) => {
		const base = baseURL as string;
		const user = email("match");
		const token = await registerAndLogin(base, user);
		try {
			await createVault(base, token, "Personal");
			await createVault(base, token, "Health");
			// Different case from the vault on purpose: the match is case-insensitive.
			const flow = await startDeviceFlow(base, {
				vault_name: "health",
				device_name: "todd-laptop",
			});

			await signInAndOpenLink(page, user, flow.user_code);

			await expect(page.getByText("Suggested", { exact: true })).toBeVisible();
			await expect(page.getByRole("radio", { name: /^Health/u })).toBeChecked();
			// The plugin's device name seeds the connection name; the new-vault field stays empty
			// so the page does not suggest creating a duplicate.
			const connection = page.getByLabel(/name this connection/iu);
			await expect(connection).toHaveValue("todd-laptop");
			await expect(page.getByLabel("New vault name")).toHaveValue("");

			await connection.fill("Desk PC");
			await page.getByRole("button", { name: "Sync", exact: true }).click();
			await expect(page.getByText(/your vault is linked/iu)).toBeVisible({ timeout: 15_000 });

			await exchangeDeviceCode(base, flow.device_code);
			const rows = await obsidianConnections(base, token);
			expect(rows).toHaveLength(1);
			expect(rows[0]?.label).toBe("Desk PC");
			expect(rows[0]?.name).toBe("Desk PC");
		} finally {
			await deleteAccount(base, user);
		}
	});

	test("creates a new vault from the plugin's name when nothing matches", async ({
		page,
		baseURL,
	}) => {
		const base = baseURL as string;
		const user = email("create");
		const token = await registerAndLogin(base, user);
		try {
			await createVault(base, token, "Personal");
			const flow = await startDeviceFlow(base, { vault_name: "Brain Dump" });

			await signInAndOpenLink(page, user, flow.user_code);

			await expect(page.getByText("Suggested", { exact: true })).toHaveCount(0);
			const name = page.getByLabel("New vault name");
			await expect(name).toHaveValue("Brain Dump");
			await expect(page.getByRole("radio", { name: /new vault name/iu })).toBeChecked();

			await page.getByRole("button", { name: "Sync", exact: true }).click();
			await expect(page.getByText(/your vault is linked/iu)).toBeVisible({ timeout: 15_000 });

			expect(await listVaultNames(base, token)).toContain("Brain Dump");
		} finally {
			await deleteAccount(base, user);
		}
	});

	test("with no vaults yet it asks for a first vault name, with no radio to pick", async ({
		page,
		baseURL,
	}) => {
		const base = baseURL as string;
		const user = email("first");
		await registerAndLogin(base, user);
		try {
			const flow = await startDeviceFlow(base, { vault_name: "My Notes" });

			await signInAndOpenLink(page, user, flow.user_code);

			await expect(page.getByText("Create your first vault")).toBeVisible();
			await expect(page.getByLabel("New vault name")).toHaveValue("My Notes");
			await expect(page.getByRole("radio")).toHaveCount(0);
		} finally {
			await deleteAccount(base, user);
		}
	});

	test("a long vault list scrolls, says how many there are, and searches", async ({
		page,
		baseURL,
	}) => {
		const base = baseURL as string;
		const user = email("long");
		const token = await registerAndLogin(base, user);
		try {
			for (let i = 1; i <= 9; i++) {
				await createVault(base, token, `Vault ${i}`);
			}
			const flow = await startDeviceFlow(base, { vault_name: "Elsewhere" });

			await signInAndOpenLink(page, user, flow.user_code);

			await expect(page.getByText(/choose from 9 vaults/u)).toBeVisible();
			await page.getByRole("button", { name: "Search vaults" }).click();
			const search = page.getByRole("searchbox", { name: "Search vaults" });
			await expect(search).toBeFocused();

			// Pick a vault, then filter it out of view: the selection must still be announced.
			await search.fill("");
			await page.getByRole("radio", { name: /^Vault 2\b/u }).click();
			await search.fill("zzz");
			await expect(page.getByText(/no vaults match/iu)).toBeVisible();
			await expect(page.getByText("Selected: Vault 2")).toBeVisible();

			await search.fill("vault 9");
			await expect(page.getByRole("radio", { name: /^Vault 9\b/u })).toBeVisible();
			await expect(page.getByRole("radio", { name: /^Vault 1\b/u })).toHaveCount(0);
		} finally {
			await deleteAccount(base, user);
		}
	});

	test("warns that linking gives the device access when the code arrived in the URL", async ({
		page,
		baseURL,
	}) => {
		const base = baseURL as string;
		const user = email("warn");
		const token = await registerAndLogin(base, user);
		try {
			await createVault(base, token, "Personal");
			const flow = await startDeviceFlow(base, {});

			await signInAndOpenLink(page, user, flow.user_code);

			await expect(
				page.getByText(/continue only if you started this link yourself/iu),
			).toBeVisible();
		} finally {
			await deleteAccount(base, user);
		}
	});
});
