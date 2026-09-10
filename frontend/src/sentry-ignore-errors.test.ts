/**
 * That the SDK actually DROPS the noise — not merely that we hand `init` an
 * array whose regexes match a string we also wrote.
 *
 * `sentry-init-wiring.test.ts` asserts `ignoreErrors` reaches `init` and that
 * its patterns match the observed message. Both halves of that are our own
 * code talking to itself: rename the option to `ignoreError` and it stays
 * green while every extension rejection ships. The behaviour under test is
 * Sentry's filtering, so this file drives the REAL SDK and inspects what left
 * through the transport.
 *
 * Its own file because it must NOT `vi.mock("@sentry/react")` the way the
 * wiring tests do, and because `Sentry.init` installs a global client.
 *
 * `./sentry` is imported DYNAMICALLY, after stubbing the DSN empty. A static
 * import evaluates that module's top-level `sentryReady`, and with a DSN in the
 * environment that starts a second, unmocked `Sentry.init` with the REAL
 * transport: it resolves after `beforeEach`, replaces the global client holding
 * `recordingTransport`, and the control test fails while the test errors are
 * POSTed to the live ingest host. Vite loads `.env.local` in test mode and
 * `.env.local.example` exists, so a developer with a DSN there would hit this
 * while CI (no DSN) stayed green.
 */
import * as Sentry from "@sentry/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const sent: string[] = [];

/** Minimal transport: records the event messages the SDK chose to send. */
const recordingTransport = () => ({
	send: (envelope: unknown) => {
		// Envelope shape is [headers, [[itemHeaders, item], ...]].
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

describe("ignoreErrors actually filters", () => {
	beforeEach(async () => {
		sent.length = 0;
		vi.stubEnv("VITE_SENTRY_DSN", "");
		vi.resetModules();
		const { sentryInitOptions } = await import("./sentry");
		Sentry.init({
			...sentryInitOptions("https://key@example.ingest.sentry.io/1"),
			transport: recordingTransport,
		});
	});

	afterEach(async () => {
		await Sentry.close(0);
		vi.unstubAllEnvs();
		vi.resetModules();
		vi.restoreAllMocks();
	});

	it("drops the browser-extension rejection", async () => {
		Sentry.captureException(new Error("Invalid call to runtime.sendMessage(). Tab not found."));
		await Sentry.flush(2000);

		expect(sent).toEqual([]);
	});

	// The control. Without this, a filter that swallowed EVERYTHING would pass
	// the test above — which is the failure mode that actually matters, since it
	// would silently end all crash reporting.
	it("still sends an ordinary application error", async () => {
		Sentry.captureException(new Error("Cannot read properties of undefined (reading 'notes')"));
		await Sentry.flush(2000);

		expect(sent).toEqual(["Cannot read properties of undefined (reading 'notes')"]);
	});
});

// captureError promises that a DEFINED return means the event was DELIVERED —
// the root boundary shows that id to the user as a support reference. The SDK
// mints the id before the inbound filter runs and then flushes an empty queue
// instantly, so without an explicit check a filtered event would hand the user
// a reference to something that will never exist in Sentry.
describe("captureError delivery contract vs the filter", () => {
	afterEach(() => {
		vi.unstubAllEnvs();
		vi.resetModules();
	});

	it("returns undefined for an error the filter drops", async () => {
		vi.stubEnv("VITE_SENTRY_DSN", "https://key@example.ingest.sentry.io/1");
		vi.resetModules();
		const { captureError } = await import("./sentry");

		await expect(
			captureError(new Error("Invalid call to runtime.sendMessage(). Tab not found.")),
		).resolves.toBeUndefined();
	});
});
