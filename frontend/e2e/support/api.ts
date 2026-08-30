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

	return access_token;
}

export async function createVault(
	baseURL: string,
	token: string,
	name: string,
): Promise<{ id: number; name: string }> {
	const res = await fetch(`${baseURL}/api/vaults/register`, {
		method: "POST",
		headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
		body: JSON.stringify({ name, client_id: crypto.randomUUID() }),
	});
	if (!res.ok) {
		throw new Error(`vault create failed: ${res.status} ${await res.text()}`);
	}
	// /vaults/register answers with the vault flat, not wrapped in { vault }.
	return (await res.json()) as { id: number; name: string };
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

// Matches "the browser is on this note's page". Notes are served at
// /v/:vaultSlug/:noteId and specs do not know the slug, so the slug segment
// stays a wildcard -- but the /v/ prefix is pinned deliberately.
//
// This used to anchor only on the trailing id, which made the whole Playwright
// suite blind to the URL shape: it matched /work/7 and /v/work/7 identically,
// so a half-migrated frontend would have shipped green. Pinning the prefix is
// the only assertion at ANY layer that runs against real Phoenix and proves
// the deployed URL shape.
export function noteUrlRe(noteId: number | string): RegExp {
	return new RegExp(`/v/[^/]+/${noteId}(?:[?#]|$)`, "u");
}

// Navigates straight to the legacy /note/:id, which the AuthGuard redirects to
// /sign-in. Seeds localStorage["engram.activeVaultId"] on the sign-in page
// BEFORE completing sign-in, not after, so the value survives the
// post-sign-in redirect and NotePage's first query targets the right vault.
// The vault-switcher's auto-select would not pick the newly created vault in
// time otherwise. Then signs in and asserts arrival on the note — via the
// legacy-note redirect, which lands on /:vaultSlug/:noteId.
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

	await expect(page).toHaveURL(noteUrlRe(noteId), { timeout: 10_000 });
}
