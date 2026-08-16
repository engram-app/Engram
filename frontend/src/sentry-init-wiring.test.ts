/**
 * That `Sentry.init` receives the scrubbers — not merely that a factory
 * exists which would produce them.
 *
 * `sentry-scrub.test.ts` asserts `sentryInitOptions()` returns
 * `beforeBreadcrumb` / `beforeSend`. That guards the factory and nothing else:
 * rewriting the call site as `Sentry.init({ dsn })` left that file green at
 * 18/18 while every breadcrumb shipped unscrubbed. The gap is the call, so
 * this file drives the real module and inspects what init was handed.
 *
 * Its own file because it needs `vi.resetModules()` plus a stubbed
 * `import.meta.env` — the DSN is read at module scope, so the module has to be
 * imported fresh, after the stub.
 */
import { afterEach, describe, expect, it, vi } from "vitest";

afterEach(() => {
	vi.unstubAllEnvs();
	vi.doUnmock("@sentry/react");
	vi.resetModules();
});

describe("Sentry.init wiring", () => {
	it("hands init the scrubbers themselves", async () => {
		const init = vi.fn();
		vi.doMock("@sentry/react", () => ({ init, captureException: vi.fn() }));
		vi.stubEnv("VITE_SENTRY_DSN", "https://key@example.ingest.sentry.io/1");
		vi.resetModules();

		const sentry = await import("./sentry");
		await sentry.sentryReady;

		expect(init).toHaveBeenCalledTimes(1);
		const options = init.mock.calls[0]?.[0] as {
			beforeBreadcrumb?: unknown;
			beforeSend?: unknown;
			sendDefaultPii?: boolean;
		};
		expect(options.beforeBreadcrumb).toBe(sentry.scrubBreadcrumb);
		expect(options.beforeSend).toBe(sentry.scrubEvent);
		expect(options.sendDefaultPii).toBe(false);
	});

	// Self-host ships no DSN. Importing the SDK at all would be a wasted chunk,
	// and init'ing it would be reporting the user did not ask for.
	it("does not initialise without a DSN", async () => {
		const init = vi.fn();
		vi.doMock("@sentry/react", () => ({ init, captureException: vi.fn() }));
		vi.stubEnv("VITE_SENTRY_DSN", "");
		vi.resetModules();

		const sentry = await import("./sentry");
		await sentry.sentryReady;

		expect(init).not.toHaveBeenCalled();
		expect(sentry.sentryReady).toBeNull();
	});
});
