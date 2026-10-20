// The web app's funnel events, also sent to our own server event log
// (`POST /api/analytics/events`), which records them only: PostHog gets them
// from the browser, so the server never forwards them (no double counting).
// The operator insights funnel reads them there.
//
// Same consent as PostHog: nothing is sent under Global Privacy Control or
// Do Not Track, nothing before the signed-in user is known to have NOT
// objected (`enable()`, from identity.ts), and nothing after an opt-out or
// sign-out (`disable()`, which also drops what was held). Transport mirrors
// remote-log.ts: batched keepalive fetch with the session token (sendBeacon
// cannot carry it), `pagehide` flush, never throws into a caller.
import { getApiBase } from "../api/base";
import { getAuthToken } from "../api/client";
import type { EngramEvent } from "./events";

const FLUSH_MS = 5000;
// The server refuses more than this per request.
const MAX_BATCH = 20;
// Held before identify or while offline: bounded, oldest dropped first.
const MAX_QUEUE = 100;

interface QueuedEvent {
	event: EngramEvent;
	props: Record<string, unknown>;
}

function browserObjects(): boolean {
	if (typeof navigator === "undefined") {
		return false;
	}
	const gpc = "globalPrivacyControl" in navigator && navigator.globalPrivacyControl === true;
	return gpc || navigator.doNotTrack === "1";
}

function createServerEvents(): ServerEventSink {
	const sink = new ServerEventSink(async () => ({
		url: getApiBase(),
		token: await getAuthToken(),
	}));
	if (typeof window !== "undefined") {
		window.addEventListener("pagehide", () => {
			sink.flush();
		});
	}
	return sink;
}

export class ServerEventSink {
	private readonly queue: QueuedEvent[] = [];
	private timer: ReturnType<typeof setTimeout> | null = null;
	// "pending" until the user is known: events are held, not sent. "off"
	// after an opt-out or sign-out: events are dropped.
	private state: "pending" | "on" | "off" = "pending";

	constructor(
		private readonly resolveTransport: () => Promise<{ url: string; token: string | null } | null>,
	) {}

	/** The signed-in user has not objected: send what is held, and what comes. */
	enable(): void {
		this.state = "on";
		this.schedule();
	}

	/** Opted out or signed out: send nothing, and forget what was held. */
	disable(): void {
		this.state = "off";
		this.queue.length = 0;
		this.clearTimer();
	}

	add(event: EngramEvent, props: Record<string, unknown>): void {
		if (this.state === "off" || browserObjects()) {
			return;
		}
		this.queue.push({ event, props });
		if (this.queue.length > MAX_QUEUE) {
			this.queue.splice(0, this.queue.length - MAX_QUEUE);
		}
		if (this.state === "on" && this.queue.length >= MAX_BATCH) {
			this.flush();
		} else {
			this.schedule();
		}
	}

	async flush(): Promise<void> {
		this.clearTimer();
		if (this.state !== "on" || this.queue.length === 0) {
			return;
		}
		if (browserObjects()) {
			this.queue.length = 0;
			return;
		}
		const batch = this.queue.splice(0, MAX_BATCH);
		this.schedule();
		try {
			const transport = await this.resolveTransport();
			if (!transport?.token) {
				return; // signed out / not ready: drop, never network
			}
			await fetch(`${transport.url}/api/analytics/events`, {
				method: "POST",
				keepalive: true,
				headers: {
					"Content-Type": "application/json",
					Authorization: `Bearer ${transport.token}`,
				},
				body: JSON.stringify({ events: batch }),
			});
		} catch {
			// Best-effort: analytics must never surface into the UI.
		}
	}

	private schedule(): void {
		if (this.state === "on" && !this.timer && this.queue.length > 0) {
			this.timer = setTimeout(() => {
				this.flush();
			}, FLUSH_MS);
		}
	}

	private clearTimer(): void {
		if (this.timer) {
			clearTimeout(this.timer);
			this.timer = null;
		}
	}
}

export const serverEvents = createServerEvents();
