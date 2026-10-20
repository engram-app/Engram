/**
 * Errors that fire before the lazy SDK chunk lands are queued by sentry.ts and
 * captured once it inits. They must meet the same beforeSend policy as the
 * SDK's own handlers: a wallet extension's `{code, message}` rejection at page
 * load is exactly the noise ENGRAM-FRONTEND-7 was, and it fires early.
 *
 * Drives the REAL SDK (its own file, like sentry-ignore-errors.test.ts), with
 * the chunk held back by a gate so events can be dispatched inside the
 * pre-init window, and a recording transport so nothing leaves the process.
 */
import { afterEach, describe, expect, it, vi } from "vitest";

const sent: string[] = [];

const recordingTransport = () => ({
	send: (envelope: unknown) => {
		const items = (envelope as [unknown, [unknown, { exception?: unknown }][]])[1] ?? [];
		for (const [, item] of items) {
			const values = (item as { exception?: { values?: { value?: string }[] } }).exception?.values;
			for (const v of values ?? []) {
				if (v.value) {
					sent.push(v.value);
				}
			}
		}
		return Promise.resolve({});
	},
	flush: () => Promise.resolve(true),
});

afterEach(async () => {
	const Sentry = await vi.importActual<typeof import("@sentry/react")>("@sentry/react");
	await Sentry.close(0);
	vi.doUnmock("@sentry/react");
	vi.unstubAllEnvs();
	vi.resetModules();
	sent.length = 0;
});

describe("the pre-init error queue", () => {
	it("applies beforeSend: drops a non-Error rejection, sends a real Error", async () => {
		let release: () => void = () => undefined;
		const gate = new Promise<void>((resolve) => {
			release = resolve;
		});
		vi.doMock("@sentry/react", async () => {
			const actual = await vi.importActual<typeof import("@sentry/react")>("@sentry/react");
			await gate;
			return {
				...actual,
				init: (options: Parameters<typeof actual.init>[0]) =>
					actual.init({ ...options, transport: recordingTransport }),
			};
		});
		vi.stubEnv("VITE_SENTRY_DSN", "https://key@example.ingest.sentry.io/1");
		vi.resetModules();
		const sentry = await import("./sentry");

		window.dispatchEvent(
			Object.assign(new Event("unhandledrejection"), {
				reason: { code: 4001, message: "wallet must has at least one account" },
			}),
		);
		window.dispatchEvent(new ErrorEvent("error", { error: new Error("early boom") }));
		release();
		const Sentry = await sentry.sentryReady;
		await Sentry?.flush(2000);

		expect(sent).toEqual(["early boom"]);
	});
});
