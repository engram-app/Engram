/**
 * main.tsx has module-scope side effects (createRoot on #root), so it cannot be
 * rendered in a test. The ErrorFallback and the top-level LoadingScreen sit
 * outside AppShell, so LocaleProvider must wrap them at the root, or both render
 * English for every user. Structural, like the other main.* wiring tests.
 */
import { describe, expect, it } from "vitest";
import source from "./main.tsx?raw";

describe("main.tsx locale wiring", () => {
	const root = source.slice(source.indexOf("createRoot("));

	it("mounts LocaleProvider above RootErrorBoundary and the top-level Suspense", () => {
		const provider = root.indexOf("<LocaleProvider>");
		expect(provider).toBeGreaterThan(-1);
		expect(provider).toBeLessThan(root.indexOf("<RootErrorBoundary>"));
		expect(provider).toBeLessThan(root.indexOf("<Suspense"));
	});

	it("does not mount a second provider inside AppShell", () => {
		expect(source.match(/<LocaleProvider>/gu)).toHaveLength(1);
	});
});
