import { setupClerkTestingToken } from "@clerk/testing/playwright";
import { expect, test } from "@playwright/test";
import {
	clerkSignIn,
	createUnonboardedUser,
	deleteClerkUser,
	loadAuthState,
} from "./clerk-helpers";

/**
 * The website-first path, end to end: a brand-new user signs up on the web,
 * walks the onboarding wizard (terms, how they heard, first vault) and writes
 * a first note that survives a reload.
 */

const NOTE_TITLE = "First note";
const NOTE_BODY = "Hello from the web";

test.describe("Website-first: a new user signs up on the web", () => {
	const skip = loadAuthState().skipped || !process.env.E2E_CLERK_SECRET_KEY;
	let pending: { email: string; id: string } | null = null;

	test.skip(() => skip, "E2E_CLERK_SECRET_KEY not set — Clerk browser tests skipped");

	test.beforeEach(async ({ page }) => {
		// Per attempt: the journey consumes the user's un-onboarded state.
		pending = await createUnonboardedUser("e2e-browser-webfirst");
		await setupClerkTestingToken({ page });
	});

	test.afterEach(async () => {
		if (pending) {
			await deleteClerkUser(pending.id);
			pending = null;
		}
	});

	test("sign up on the web, onboard, write a first note", {
		tag: ["@canary"],
		annotation: [
			{ type: "cadence", description: "hourly" },
			{ type: "targets", description: "ci,staging" },
		],
	}, async ({ page }) => {
		await test.step("sign-in", async () => {
			await clerkSignIn(page, (pending as { email: string }).email, "/");
			await page.waitForURL(/\/onboard\/agreement/u, { timeout: 25_000 });
		});

		await test.step("terms", async () => {
			await page.getByLabel(/I have read and agree/iu).click();
			await page.getByRole("button", { name: /^continue$/iu }).click();
			await page.waitForURL(/\/onboard\/heard/u, { timeout: 25_000 });
		});

		await test.step("heard", async () => {
			await page.getByRole("radio", { name: "Search engine" }).click();
			await page.getByRole("button", { name: /^continue$/iu }).click();
			await page.waitForURL(/\/onboard\/vault/u, { timeout: 25_000 });
		});

		await test.step("vault", async () => {
			await page.getByRole("button", { name: /starting fresh/iu }).click();
			await page.getByLabel("Vault name").fill("Journey Vault");
			await page.getByRole("button", { name: /create vault & continue/iu }).click();
			await expect(page.getByRole("navigation", { name: "App navigation" })).toBeVisible({
				timeout: 25_000,
			});
		});

		await test.step("first-note", async () => {
			await page.getByRole("button", { name: "New note", exact: true }).click();
			// A new note opens with its title in rename mode.
			const rename = page.getByRole("region", { name: "Rename note" }).getByRole("textbox");
			await expect(rename).toBeVisible({ timeout: 15_000 });
			await rename.fill(NOTE_TITLE);
			await rename.press("Enter");
			await expect(page.getByRole("heading", { name: NOTE_TITLE })).toBeVisible();

			const editor = page.locator(".cm-content");
			await editor.click();
			await page.keyboard.type(NOTE_BODY);
			await expect(editor).toContainText(NOTE_BODY);
		});

		await test.step("note-persists", async () => {
			// ponytail: the editor has no save indicator; the live channel flushes
			// each keystroke, so give it a beat before dropping the page.
			await page.waitForTimeout(2000);
			await page.reload();
			const row = page.getByRole("treeitem", { name: NOTE_TITLE, exact: true });
			await expect(row).toBeVisible({ timeout: 20_000 });
			await row.click();
			await expect(page.locator(".cm-content")).toContainText(NOTE_BODY, { timeout: 15_000 });
		});
	});
});
