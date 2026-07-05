import { expect, test } from "@playwright/test";
import { createVault, registerAndLogin, signInForNote, upsertNote } from "./support/api";
import { row, treeRoot } from "./support/tree";

test.describe("web tree ops sync (web to web)", () => {
	test("smoke: signed-in tab shows the folder tree with a seeded note", async ({
		browser,
		baseURL,
	}) => {
		const email = `e2e-tree-smoke-${Date.now()}@test.com`;
		const token = await registerAndLogin(baseURL!, email);
		const vault = await createVault(baseURL!, token, `treesmoke-${Date.now()}`);
		const { id: noteId } = await upsertNote(baseURL!, token, vault.id, "alpha.md", "body only\n");

		const ctx = await browser.newContext();
		const page = await ctx.newPage();
		await signInForNote(page, email, vault.id, noteId);

		await expect(treeRoot(page)).toBeVisible({ timeout: 10_000 });
		await expect(row(page, "alpha")).toBeVisible({ timeout: 10_000 });

		await ctx.close();
	});
});
