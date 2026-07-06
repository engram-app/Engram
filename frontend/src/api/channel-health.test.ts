import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { installSocketHealthTriggers } from "./channel";

// installSocketHealthTriggers wires focus/visibilitychange/online to a wake
// health check. A single wake emits a BURST of those events; the trigger
// coalesces the burst (trailing edge) and lets the strongest signal win:
// reconnect (session-preserving, fresh-token) fires when the socket is dead OR
// a wake signal implies it's stale despite reading OPEN (half-open) — an
// `online` transition or a long hidden gap. A live socket on a short wake just
// backfills. reconnect / backfill / isConnected are injected — no phoenix mock.

// Must exceed WAKE_COALESCE_MS in channel.ts so the trailing-edge action fires.
const SETTLE_MS = 600;

let cleanup: (() => void) | null = null;
let visibility: DocumentVisibilityState = "visible";

beforeEach(() => {
	vi.useFakeTimers();
	visibility = "visible";
	vi.spyOn(document, "visibilityState", "get").mockImplementation(() => visibility);
});
afterEach(() => {
	cleanup?.();
	cleanup = null;
	vi.useRealTimers();
	vi.restoreAllMocks();
});

function hide() {
	visibility = "hidden";
	document.dispatchEvent(new Event("visibilitychange"));
}
function show() {
	visibility = "visible";
	document.dispatchEvent(new Event("visibilitychange"));
}

describe("installSocketHealthTriggers", () => {
	// The bug this fix targets: on a half-open socket isConnected() lies "true".
	// focus fires first in the wake burst and would only backfill; the online
	// event must still force the reconnect even though it arrives second.
	it("forces reconnect through a half-open socket when online follows focus in one burst", () => {
		const reconnect = vi.fn();
		const backfill = vi.fn();
		cleanup = installSocketHealthTriggers(reconnect, backfill, () => true);

		window.dispatchEvent(new Event("focus")); // sees half-open as "connected"
		window.dispatchEvent(new Event("online")); // must force through that lie
		vi.advanceTimersByTime(SETTLE_MS);

		expect(reconnect).toHaveBeenCalledTimes(1);
		expect(backfill).not.toHaveBeenCalled();
	});

	it("reconnects on online even when the socket reports connected (half-open)", () => {
		const reconnect = vi.fn();
		const backfill = vi.fn();
		cleanup = installSocketHealthTriggers(reconnect, backfill, () => true);

		window.dispatchEvent(new Event("online"));
		vi.advanceTimersByTime(SETTLE_MS);

		expect(reconnect).toHaveBeenCalledTimes(1);
		expect(backfill).not.toHaveBeenCalled();
	});

	it("reconnects a dead socket on focus", () => {
		const reconnect = vi.fn();
		cleanup = installSocketHealthTriggers(reconnect, vi.fn(), () => false);

		window.dispatchEvent(new Event("focus"));
		vi.advanceTimersByTime(SETTLE_MS);

		expect(reconnect).toHaveBeenCalledTimes(1);
	});

	it("only backfills on focus when the socket is live", () => {
		const reconnect = vi.fn();
		const backfill = vi.fn();
		cleanup = installSocketHealthTriggers(reconnect, backfill, () => true);

		window.dispatchEvent(new Event("focus"));
		vi.advanceTimersByTime(SETTLE_MS);

		expect(backfill).toHaveBeenCalledTimes(1);
		expect(reconnect).not.toHaveBeenCalled();
	});

	it("reconnects on becoming visible after a long hidden gap, even if connected", () => {
		const reconnect = vi.fn();
		const backfill = vi.fn();
		cleanup = installSocketHealthTriggers(reconnect, backfill, () => true);

		hide();
		vi.advanceTimersByTime(20_000); // hidden past the staleness threshold
		show();
		vi.advanceTimersByTime(SETTLE_MS);

		expect(reconnect).toHaveBeenCalledTimes(1);
		expect(backfill).not.toHaveBeenCalled();
	});

	it("only backfills on becoming visible after a short hidden gap", () => {
		const reconnect = vi.fn();
		const backfill = vi.fn();
		cleanup = installSocketHealthTriggers(reconnect, backfill, () => true);

		hide();
		vi.advanceTimersByTime(3000); // brief tab switch
		show();
		vi.advanceTimersByTime(SETTLE_MS);

		expect(backfill).toHaveBeenCalledTimes(1);
		expect(reconnect).not.toHaveBeenCalled();
	});

	it("does nothing on the hidden transition itself", () => {
		const reconnect = vi.fn();
		const backfill = vi.fn();
		cleanup = installSocketHealthTriggers(reconnect, backfill, () => false);

		hide();
		vi.advanceTimersByTime(SETTLE_MS);

		expect(reconnect).not.toHaveBeenCalled();
		expect(backfill).not.toHaveBeenCalled();
	});

	it("coalesces a wake burst (focus+online) into one action", () => {
		const reconnect = vi.fn();
		cleanup = installSocketHealthTriggers(reconnect, vi.fn(), () => false);

		window.dispatchEvent(new Event("focus"));
		window.dispatchEvent(new Event("online"));
		vi.advanceTimersByTime(SETTLE_MS);

		expect(reconnect).toHaveBeenCalledTimes(1);
	});

	it("acts again on a wake after the previous burst settled", () => {
		const reconnect = vi.fn();
		cleanup = installSocketHealthTriggers(reconnect, vi.fn(), () => false);

		window.dispatchEvent(new Event("focus"));
		vi.advanceTimersByTime(SETTLE_MS);
		window.dispatchEvent(new Event("focus"));
		vi.advanceTimersByTime(SETTLE_MS);

		expect(reconnect).toHaveBeenCalledTimes(2);
	});

	it("stops acting after cleanup", () => {
		const reconnect = vi.fn();
		const remove = installSocketHealthTriggers(reconnect, vi.fn(), () => false);
		remove();

		window.dispatchEvent(new Event("focus"));
		window.dispatchEvent(new Event("online"));
		show();
		vi.advanceTimersByTime(SETTLE_MS);

		expect(reconnect).not.toHaveBeenCalled();
	});
});
