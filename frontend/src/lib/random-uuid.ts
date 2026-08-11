import { uuid7 } from "@/crdt/uuid7";

/**
 * A random UUID, on any origin.
 *
 * `crypto.randomUUID` is a SECURE-CONTEXT-only API. localhost and 127.0.0.1
 * count as secure even over plain http; a bare LAN IP does not. So it is
 * undefined whenever the app is served over http from anything but localhost —
 * a phone pointed at the dev server, or a self-host reached at
 * http://192.168.x.x — and calling it there throws a TypeError.
 *
 * Prefer it when it exists rather than always minting v7: on HTTPS this keeps
 * the v4 the app has always used, with its full 122 bits of entropy and no
 * embedded timestamp. uuid7 (built on crypto.getRandomValues, which is NOT
 * gated) carries ~74 random bits and encodes creation time, which is the right
 * trade to stay working but the wrong one to adopt everywhere by default.
 */
export function randomUuid(): string {
	return crypto.randomUUID?.() ?? uuid7();
}
