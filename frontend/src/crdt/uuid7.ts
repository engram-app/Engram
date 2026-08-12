/** Minimal UUIDv7 (RFC 9562 §5.7) minter — ported from the plugin
 * (engram-obsidian-sync `src/crdt/uuid7.ts`) so the web mints note_ids the same
 * way the backend/plugin expect.
 *
 * `crypto.randomUUID()` only produces v4 — random, no time ordering. A
 * brand-new note's client-minted
 * id must be roughly creation-ordered (v7 embeds a 48-bit ms timestamp in the top
 * bits) so ids sort consistently with the backend Postgres uuid ordering; a v4
 * won't do. No `uuid` package is in package.json, so this stays a small
 * self-contained generator instead of a new dependency.
 *
 * It is also the app's only id source that works off a secure context —
 * crypto.getRandomValues below is not gated, whereas crypto.randomUUID is —
 * which is why `lib/random-uuid` falls back to this. For a plain random id,
 * call randomUuid() rather than crypto.randomUUID directly; reserve this for
 * ids that genuinely need to be time-ordered, like note ids.
 *
 * ponytail: "roughly" ordered — same-ms ties fall back to pure randomness (no
 * monotonic counter), fine for a note_id nonce. Swap for a lib if strict per-ms
 * monotonic ordering ever matters.
 */
export function uuid7(): string {
	const tsHex = Date.now().toString(16).padStart(12, "0").slice(-12);
	const rand = new Uint8Array(10);
	crypto.getRandomValues(rand);
	// version 7 nibble: keep low 4 bits (% 16), set high nibble to 7 (+ 0x70).
	rand[0] = ((rand[0] ?? 0) % 16) + 0x70;
	// variant 10xx: keep low 6 bits (% 64), set the top two bits to 10 (+ 0x80).
	rand[2] = ((rand[2] ?? 0) % 64) + 0x80;
	const hex = (arr: Uint8Array) => Array.from(arr, (b) => b.toString(16).padStart(2, "0")).join("");
	return [
		tsHex.slice(0, 8),
		tsHex.slice(8, 12),
		hex(rand.subarray(0, 2)),
		hex(rand.subarray(2, 4)),
		hex(rand.subarray(4, 10)),
	].join("-");
}
