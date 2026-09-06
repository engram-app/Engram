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
 */
import * as Sentry from "@sentry/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { sentryInitOptions } from "./sentry";

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
	beforeEach(() => {
		sent.length = 0;
		Sentry.init({
			...sentryInitOptions("https://key@example.ingest.sentry.io/1"),
			transport: recordingTransport,
		});
	});

	afterEach(async () => {
		await Sentry.close(0);
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
