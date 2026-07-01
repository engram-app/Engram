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
	deviceId = readStored() ?? crypto.randomUUID();
	writeStored(deviceId);
	return deviceId;
}

/** Test hook: drop the in-memory cache so the next read re-reads storage. */
export function __resetDeviceIdCache(): void {
	deviceId = null;
}
