import { expect, test } from "@playwright/test";
import { createVault, registerAndLogin, signIn } from "./support/api";

test.describe("Mobile layout", () => {
	test.use({ viewport: { width: 390, height: 844 } });

	// One sign-in for all three checks: each is a read of the same signed-in
	// mobile shell, so separate tests only paid for extra registrations.
	test("hamburger opens the files drawer, no resize handles, drawers reset on navigation", async ({
		page,
		baseURL,
	}) => {
		const base = baseURL as string;
		const email = `e2e-mobile-${Date.now()}@test.com`;
		const token = await registerAndLogin(base, email);
		await createVault(base, token, "E2E Vault");
		await signIn(page, email);
		await expect(page).toHaveURL("/");

		// Desktop resize handles are not rendered on mobile.
		await expect(page.locator("[data-panel-resize-handle-id]")).toHaveCount(0);

		// Header shows the hamburger; tapping it opens the files drawer.
		const filesTrigger = page.getByRole("button", { name: "Open files" });
		await expect(filesTrigger).toBeVisible();
		await filesTrigger.click();
		await expect(page.getByRole("dialog")).toBeVisible();
		await expect(page.getByRole("heading", { name: "Files" })).toBeVisible();

		// Drawers start closed on every navigation.
		await page.goto("/settings");
		await expect(page.getByRole("dialog")).toHaveCount(0);
	});
});
