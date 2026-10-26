import { expect, type Locator, type Page, test } from "@playwright/test";
import { createVault, registerAndLogin, signInForNote, upsertNote } from "./support/api";
import { openContextMenu, pickAction, row } from "./support/tree";

/**
 * iPhone editing guards, run with the iPhone 15 descriptor (the `ios` project
 * in playwright.config.ts). It runs in Chromium for now: see that project for
 * why not WebKit. What it asserts does not depend on the engine.
 *
 * It cannot raise a soft keyboard, so it guards the causes rather than the
 * symptoms: text fields under 16px make iOS zoom the page, an editor with
 * prediction off leaves the QuickType row to AutoFill, and live property
 * inputs above the editor are where iOS's prev/next arrows land.
 */

/** Computed font size in px. */
function fontSize(el: Locator): Promise<number> {
	return el.evaluate((node) => Number.parseFloat(getComputedStyle(node).fontSize));
}

/** Every visible text field on the page that iOS would zoom on focus. */
async function smallTextFields(page: Page): Promise<string[]> {
	return page.evaluate(() =>
		[
			...document.querySelectorAll<HTMLElement>(
				"input:not([type=checkbox]):not([type=radio]):not([type=file]):not([type=hidden]), textarea",
			),
		]
			.filter((el) => el.getClientRects().length > 0)
			.filter((el) => Number.parseFloat(getComputedStyle(el).fontSize) < 16)
			.map((el) => el.getAttribute("aria-label") ?? el.getAttribute("placeholder") ?? el.outerHTML),
	);
}

test("iPhone: 16px fields, prose typing on, properties are buttons until tapped", async ({
	page,
	baseURL,
}) => {
	const base = baseURL as string;
	const email = `e2e-ios-${Date.now()}@test.com`;
	const token = await registerAndLogin(base, email);
	const vault = await createVault(base, token, "iOS Vault");
	const { id } = await upsertNote(
		base,
		token,
		vault.id,
		"ios.md",
		"---\nstatus: draft\n---\n\nBody text.",
	);
	await signInForNote(page, email, vault.id, id);

	// Properties: buttons at rest, so prev/next from the editor has no input to
	// land on.
	const props = page.getByTestId("note-properties");
	await expect(props.getByRole("button", { name: "Rename status" })).toBeVisible({
		timeout: 15_000,
	});
	await expect(props.getByRole("button", { name: "status value" })).toHaveText("draft");
	await expect(props.locator("input:not([type=checkbox]), textarea")).toHaveCount(0);

	// The editor: prediction on (or iOS fills QuickType with AutoFill), and
	// spellcheck must stay on, it is the only misspelling signal the editor has.
	const content = page.locator(".cm-content").first();
	await expect(content).toHaveAttribute("autocorrect", "on");
	await expect(content).toHaveAttribute("autocapitalize", "sentences");
	await expect(content).toHaveAttribute("spellcheck", "true");
	expect(await fontSize(content)).toBeGreaterThanOrEqual(16);

	// Tapping a value opens a real field, at 16px so iOS does not zoom.
	await props.getByRole("button", { name: "status value" }).tap();
	const value = props.getByRole("textbox", { name: "status value" });
	await expect(value).toBeFocused();
	expect(await fontSize(value)).toBeGreaterThanOrEqual(16);
	await value.press("Escape");

	await props.getByRole("button", { name: "Rename status" }).tap();
	const key = props.getByRole("textbox", { name: "Rename status" });
	await expect(key).toBeFocused();
	expect(await fontSize(key)).toBeGreaterThanOrEqual(16);
	await key.press("Escape");

	// The new-property row's two live inputs.
	await props.getByRole("button", { name: "Add property" }).tap();
	await expect(page.getByPlaceholder("Property name")).toBeVisible();
	expect(await smallTextFields(page)).toEqual([]);
	await page.getByPlaceholder("Property name").press("Escape");

	// Tree rename, inside the mobile files drawer.
	await page.getByRole("button", { name: "Open files" }).tap();
	await expect(row(page, "ios")).toBeVisible();
	await openContextMenu(page, "ios");
	await pickAction(page, "Rename");
	const rename = page.getByTestId("tree-rename-input");
	await expect(rename).toBeVisible();
	expect(await fontSize(rename)).toBeGreaterThanOrEqual(16);
	expect(await smallTextFields(page)).toEqual([]);
});
