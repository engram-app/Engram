import { expect, type Page } from "@playwright/test";

export const PASS = "E2eTestPass!99";

export async function registerAndLogin(baseURL: string, email: string): Promise<string> {
	const reg = await fetch(`${baseURL}/api/auth/register`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ email, password: PASS }),
	});
	if (!reg.ok && reg.status !== 422) {
		throw new Error(`register failed: ${reg.status} ${await reg.text()}`);
	}

	const login = await fetch(`${baseURL}/api/auth/login`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ email, password: PASS }),
	});
	if (!login.ok) {
		throw new Error(`login failed: ${login.status} ${await login.text()}`);
	}
	const { access_token } = (await login.json()) as { access_token: string };

	const auth = { "Content-Type": "application/json", Authorization: `Bearer ${access_token}` };
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

	return access_token;
}

export async function createVault(
	baseURL: string,
	token: string,
	name: string,
): Promise<{ id: number; name: string }> {
	const res = await fetch(`${baseURL}/api/vaults`, {
		method: "POST",
		headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
		body: JSON.stringify({ name }),
	});
	if (!res.ok) {
		throw new Error(`vault create failed: ${res.status} ${await res.text()}`);
	}
	const { vault } = (await res.json()) as { vault: { id: number; name: string } };
	return vault;
}

export async function upsertNote(
	baseURL: string,
	token: string,
	vaultId: number,
	path: string,
	content: string,
	version?: number,
): Promise<{ id: number }> {
	const res = await fetch(`${baseURL}/api/notes`, {
		method: "POST",
		headers: {
			"Content-Type": "application/json",
			Authorization: `Bearer ${token}`,
			"X-Vault-Id": String(vaultId),
		},
		body: JSON.stringify({ path, content, mtime: Date.now() / 1000, version }),
	});
	if (!res.ok) {
		throw new Error(`note upsert failed: ${res.status} ${await res.text()}`);
	}
	const { note } = (await res.json()) as { note: { id: number } };
	return { id: note.id };
}

export async function createFolder(
	baseURL: string,
	token: string,
	vaultId: number,
	folder: string,
): Promise<void> {
	const res = await fetch(`${baseURL}/api/folders`, {
		method: "POST",
		headers: {
			"Content-Type": "application/json",
			Authorization: `Bearer ${token}`,
			"X-Vault-Id": String(vaultId),
		},
		body: JSON.stringify({ folder }),
	});
	if (!res.ok) {
		throw new Error(`folder create failed: ${res.status} ${await res.text()}`);
	}
}

// Navigates straight to /note/:id, which the AuthGuard redirects to
// /sign-in. Seeds localStorage["engram.activeVaultId"] on the sign-in page
// BEFORE completing sign-in, not after, so the value survives the
// post-sign-in redirect and NotePage's first query targets the right vault.
// The vault-switcher's auto-select would not pick the newly created vault in
// time otherwise. Then signs in and asserts arrival back at /note/:id.
export async function signInForNote(
	page: Page,
	email: string,
	vaultId: number,
	noteId: number,
): Promise<void> {
	await page.goto(`/note/${noteId}`);
	await expect(page).toHaveURL(/\/sign-in/u, { timeout: 10_000 });

	await page.evaluate((id) => {
		localStorage.setItem("engram.activeVaultId", String(id));
	}, vaultId);

	await page.getByLabel("Email").fill(email);
	await page.getByLabel("Password", { exact: true }).fill(PASS);
	await page.getByRole("button", { name: /sign in/iu }).click();

	await expect(page).toHaveURL(new RegExp(`/note/${noteId}`), { timeout: 10_000 });
}
