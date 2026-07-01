/** Head-cursor id sentinel. Larger than any real UUID, so seeding the cursor to
 *  `(change_seq, MAX_UUID)` makes the first pull return only `seq > change_seq`
 *  (rows AT change_seq are already rendered by the normal queries). Must be a
 *  valid UUID — the backend decode validates `id` via Ecto.UUID.cast. */
export const MAX_UUID = "ffffffff-ffff-ffff-ffff-ffffffffffff";

/** Mirror of backend `Engram.Sync.encode_cursor/2`: url-safe base64 of
 *  "<seq>:<id>" with padding stripped. seq+uuid are ASCII, so btoa is safe. */
export function encodeCursor(seq: number, id: string): string {
	return btoa(`${seq}:${id}`).replace(/\+/gu, "-").replace(/\//gu, "_").replace(/[=]+$/u, "");
}

// Per-vault: `seq` is vault-scoped, so each vault tracks its own cursor.
function cursorKey(vaultId: string): string {
	return `engram.syncCursor.${vaultId}`;
}

export function getCursor(vaultId: string): string | null {
	try {
		const raw = localStorage.getItem(cursorKey(vaultId));
		return raw && raw.length > 0 ? raw : null;
	} catch {
		return null;
	}
}

export function setCursor(vaultId: string, cursor: string): void {
	try {
		localStorage.setItem(cursorKey(vaultId), cursor);
	} catch {
		// ignore — private browsing, storage disabled, etc.
	}
}
