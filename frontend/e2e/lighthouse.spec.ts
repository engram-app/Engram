import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { type BrowserContext, chromium, expect, test } from "@playwright/test";
import lighthouse, { type Flags } from "lighthouse";
import desktopConfig from "lighthouse/core/config/desktop-config.js";
import {
	createVault,
	deleteAccount,
	registerAndLogin,
	signInForNote,
	upsertNote,
} from "./support/api";

// Lighthouse gate on a signed-in note page, the screen the app lives on.
//
// Audits the PRODUCTION bundle as Phoenix serves it (`/` on the backend port),
// not the Vite dev server: dev injects CSS from JS, so its splash paints
// unstyled and reports a ~0.5 layout shift that production never has. CI
// builds the SPA into priv/static/app before this runs; locally, run
// `bun run build:selfhost` first.
//
// Gated: accessibility, best practices, CLS. Reported only: performance score
// and LCP. Shared CI runners are too noisy to gate load time on.
//
// Its own Playwright project, whose baseURL is the backend (playwright.config).

// One Lighthouse run (navigation + audits) on a shared runner, with headroom.
const AUDIT_TIMEOUT_MS = 180_000;

const NOTE = `---
tags: [lighthouse]
status: draft
---
# Lighthouse

- [ ] an open task
- [x] a done task

Some **bold** text and a [[Missing link]].
`;

let context: BrowserContext;
let backend: string;
let port: number;
let noteUrl: string;
let profile: string;
const email = `e2e-lighthouse-${Date.now()}@test.com`;

test.describe.configure({ mode: "serial" });

test.beforeAll(async () => {
	backend = test.info().project.use.baseURL ?? "";
	const index = await fetch(`${backend}/`);
	const html = await index.text();
	if (!(index.ok && html.includes('id="root"') && !html.includes("/src/main.tsx"))) {
		throw new Error(
			`${backend}/ is not serving a production SPA build. Run \`bun run build:selfhost\` first.`,
		);
	}

	const token = await registerAndLogin(backend, email);
	const vault = await createVault(backend, token, "Lighthouse Vault");
	const note = await upsertNote(backend, token, vault.id, "Lighthouse.md", NOTE);

	// A persistent context IS the browser's default context, so the session
	// cookie set here is the one Lighthouse's own tab sees. Port 0 lets Chrome
	// pick a free port and write it to DevToolsActivePort.
	profile = mkdtempSync(join(tmpdir(), "engram-lh-"));
	context = await chromium.launchPersistentContext(profile, {
		baseURL: backend,
		args: ["--remote-debugging-port=0"],
	});
	const portFile = join(profile, "DevToolsActivePort");
	await expect.poll(() => existsSync(portFile)).toBe(true);
	port = Number(readFileSync(portFile, "utf8").split("\n")[0]);

	const page = await context.newPage();
	await signInForNote(page, email, vault.id, note.id);
	await expect(page.locator(".cm-content")).toBeVisible();
	noteUrl = page.url();
	await page.close();
});

test.afterAll(async () => {
	await context?.close();
	await deleteAccount(backend, email);
	if (profile) {
		rmSync(profile, { recursive: true, force: true });
	}
});

async function audit(formFactor: "mobile" | "desktop"): Promise<void> {
	test.setTimeout(AUDIT_TIMEOUT_MS);
	const testInfo = test.info();
	const flags: Flags = {
		port,
		output: "html",
		logLevel: "error",
		// Keep the session: the default reset would sign us out and audit /sign-in.
		disableStorageReset: true,
		onlyCategories: ["accessibility", "best-practices", "performance"],
	};
	const result = await lighthouse(
		noteUrl,
		flags,
		formFactor === "desktop" ? desktopConfig : undefined,
	);
	if (!result) {
		throw new Error("Lighthouse returned no result");
	}
	const { lhr, report } = result;
	// On disk, not an in-memory attachment: CI's `github` reporter keeps no
	// report, and test-results/ is what the job uploads on failure.
	const reportPath = testInfo.outputPath(`lighthouse-${formFactor}.html`);
	writeFileSync(reportPath, String(report));
	await testInfo.attach(`lighthouse-${formFactor}.html`, {
		path: reportPath,
		contentType: "text/html",
	});

	// It must have audited the note, not a redirect to sign-in.
	expect(lhr.finalDisplayedUrl).toBe(noteUrl);

	const score = (id: string) => Math.round((lhr.categories[id]?.score ?? 0) * 100);
	const cls = lhr.audits["cumulative-layout-shift"]?.numericValue ?? Number.NaN;
	const lcp = lhr.audits["largest-contentful-paint"]?.numericValue ?? Number.NaN;
	const failing = Object.values(lhr.audits)
		.filter((a) => a.score !== null && a.score < 1 && a.scoreDisplayMode === "binary")
		.map((a) => a.id);
	const summary = `${formFactor}: a11y ${score("accessibility")}, best-practices ${score("best-practices")}, perf ${score("performance")}, LCP ${Math.round(lcp)}ms, CLS ${cls.toFixed(3)}; failing: ${failing.join(", ") || "none"}`;
	// Logged so the numbers land in the CI log even when every gate passes.
	console.log(`[lighthouse] ${summary}`);
	testInfo.annotations.push({ type: "lighthouse", description: summary });

	expect.soft(score("accessibility"), `failing audits: ${failing.join(", ")}`).toBe(100);
	expect
		.soft(score("best-practices"), `failing audits: ${failing.join(", ")}`)
		.toBeGreaterThanOrEqual(90);
	expect.soft(cls, "cumulative layout shift").toBeLessThanOrEqual(0.1);
}

test("note page passes Lighthouse (mobile)", () => audit("mobile"));
test("note page passes Lighthouse (desktop)", () => audit("desktop"));
