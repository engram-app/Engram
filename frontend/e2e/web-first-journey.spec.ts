import { setupClerkTestingToken } from "@clerk/testing/playwright";
import { expect, test } from "@playwright/test";
import {
	API_URL,
	acceptTerms,
	answerHeard,
	clerkSignIn,
	createUnonboardedUser,
	createWizardVault,
	deleteClerkUser,
	loadAuthState,
	spaApiHeaders,
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
			await page.waitForURL(/\/onboard\//u, { timeout: 25_000 });
		});

		await test.step("terms", () => acceptTerms(page));
		await test.step("heard", () => answerHeard(page));
		await test.step("vault", () => createWizardVault(page, "Journey Vault"));

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
			// The editor has no save indicator, and after a reload the body can come
			// from local IndexedDB. Prove the SERVER has it: poll the notes API with
			// the same Clerk token and vault the SPA sends.
			await expect
				.poll(
					async () => {
						const res = await page.request.get(
							`${API_URL}/api/notes/${encodeURIComponent(`${NOTE_TITLE}.md`)}`,
							{ headers: await spaApiHeaders(page) },
						);
						return res.ok() ? await res.text() : `HTTP ${res.status()}`;
					},
					{ timeout: 30_000, message: "server never received the note body" },
				)
				.toContain(NOTE_BODY);
			await page.reload();
			const row = page.getByRole("treeitem", { name: NOTE_TITLE, exact: true });
			await expect(row).toBeVisible({ timeout: 20_000 });
			await row.click();
			await expect(page.locator(".cm-content")).toContainText(NOTE_BODY, { timeout: 15_000 });
		});
	});
});
