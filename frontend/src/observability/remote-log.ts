// Batched remote logger for the web SPA — the browser-side sibling of the
// Obsidian plugin's `rlog`. Ships breadcrumbs to the backend's authed
// `POST /api/logs` ingest (the same `client_logs` pipeline the plugin uses:
// rows are queryable per device via GET /api/logs, and warn+error re-emit
// into the server log stream that ships to Loki).
//
// Motivation (2026-07-14 deaf-note incident): the browser was a black box —
// diagnosing a one-directional live-sync failure required attaching a CDP
// WebSocket sniffer to the user's tab. The CRDT lifecycle breadcrumbs wired
// through this module make that hunt a Loki/`GET /api/logs` query instead.
//
// NOT gated on `tracingEnabled` — logs are the incident-response floor and
// must flow on every deployment shape; the trace beacon stays dark-launched
// separately. Transport mirrors `BeaconBuffer`: batched, keepalive fetch,
// fire-and-forget, `pagehide` flush, never throws into a caller.
import { getActiveVaultId } from "../api/active-vault";
import { getApiBase } from "../api/base";
import { getAuthToken } from "../api/client";
import { getDeviceId } from "../api/device-id";

const FLUSH_MS = 5000;
const MAX_BATCH = 20;
// Hard cap on buffered-but-unsent lines: a wedged transport (signed out,
// offline) must not grow memory without bound. Oldest lines drop first —
// the newest breadcrumbs are the ones an incident needs.
const MAX_QUEUE = 200;
const MAX_MESSAGE_CHARS = 500;

function createRemoteLog(): RemoteLogBuffer {
	const buf = new RemoteLogBuffer(async () => ({
		url: getApiBase(),
		token: await getAuthToken(),
		vaultId: getActiveVaultId(),
		deviceId: getDeviceId(),
	}));
	if (typeof window !== "undefined") {
		window.addEventListener("pagehide", () => {
			buf.flush();
		});
	}
	return buf;
}

export type RemoteLogLevel = "info" | "warn" | "error";

export interface RemoteLogEntry {
	ts: string;
	level: RemoteLogLevel;
	category: string;
	message: string;
	platform: string;
}

export class RemoteLogBuffer {
	private readonly queue: RemoteLogEntry[] = [];
	private timer: ReturnType<typeof setTimeout> | null = null;

	constructor(
		private readonly resolveTransport: () => Promise<{
			url: string;
			token: string | null;
			vaultId: string | null;
			deviceId: string;
		} | null>,
	) {}

	log(level: RemoteLogLevel, category: string, message: string): void {
		this.queue.push({
			ts: new Date().toISOString(),
			level,
			category,
			message: message.slice(0, MAX_MESSAGE_CHARS),
			platform: "web",
		});
		if (this.queue.length > MAX_QUEUE) {
			this.queue.splice(0, this.queue.length - MAX_QUEUE);
		}
		if (this.queue.length >= MAX_BATCH) {
			this.flush();
		} else if (!this.timer) {
			this.timer = setTimeout(() => {
				this.flush();
			}, FLUSH_MS);
		}
	}

	async flush(): Promise<void> {
		if (this.timer) {
			clearTimeout(this.timer);
			this.timer = null;
		}
		if (this.queue.length === 0) {
			return;
		}
		const batch = this.queue.splice(0, this.queue.length);
		try {
			const transport = await this.resolveTransport();
			if (!transport?.token) {
				return; // signed out / not ready: drop silently, never network
			}
			await fetch(`${transport.url}/api/logs`, {
				method: "POST",
				keepalive: true,
				headers: {
					"Content-Type": "application/json",
					Authorization: `Bearer ${transport.token}`,
					...(transport.vaultId ? { "X-Vault-ID": transport.vaultId } : {}),
					"X-Device-Id": transport.deviceId,
				},
				body: JSON.stringify({ logs: batch }),
			});
		} catch {
			// Best-effort: a logging failure must never surface into sync/UI.
		}
	}
}

export const remoteLog = createRemoteLog();

/** Web-side `rlog`: `rlog().warn("crdt", "...")`. Info lines land in the
 *  queryable `client_logs` table; warn/error additionally re-emit into the
 *  server log stream shipped to Loki. */
export function rlog(): {
	info: (category: string, message: string) => void;
	warn: (category: string, message: string) => void;
	error: (category: string, message: string) => void;
} {
	return {
		info: (category, message) => remoteLog.log("info", category, message),
		warn: (category, message) => remoteLog.log("warn", category, message),
		error: (category, message) => remoteLog.log("error", category, message),
	};
}
