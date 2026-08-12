import { randomUuid } from "@/lib/random-uuid";

const STORAGE_KEY = "engram.deviceId";

let deviceId: string | null = null;

function readStored(): string | null {
	try {
		const raw = localStorage.getItem(STORAGE_KEY);
		return raw && raw.length > 0 ? raw : null;
	} catch {
		return null;
	}
}

function writeStored(id: string): void {
	try {
		localStorage.setItem(STORAGE_KEY, id);
	} catch {
		// ignore — private browsing, storage disabled, etc.
	}
}

/**
 * Stable random per-install device id (UUID), minted once and persisted in
 * localStorage. Sent as `X-Device-Id` so the backend can attribute a sync
 * watermark to this browser. A localStorage clear / new browser mints a fresh
 * id → one clean re-bootstrap (safe by design — the web has no local mirror).
 */
export function getDeviceId(): string {
	if (deviceId) {
		return deviceId;
	}
	// randomUuid(), not crypto.randomUUID() directly: the latter is
	// secure-context-only, so it is undefined when the app is served over plain
	// http from anything but localhost — a phone pointed at the dev server, or a
	// self-host reached at http://192.168.x.x. This is the first call after
	// sign-in (it stamps X-Device-Id), so the TypeError surfaced as a permanent
	// loading screen with no client log, the log shipper needing the device id
	// too. On HTTPS the helper still returns the same v4 as before.
	deviceId = readStored() ?? randomUuid();
	writeStored(deviceId);
	return deviceId;
}

/** Test hook: drop the in-memory cache so the next read re-reads storage. */
export function __resetDeviceIdCache(): void {
	deviceId = null;
}
