/**
 * CRDT structural ops (note create/delete) over the phoenix `crdt:` channel,
 * mirroring the plugin's contract. These replace the REST `POST /notes`,
 * `POST /notes/batch-delete`, and `DELETE /notes/by-id` writes (web REST-purge,
 * issue #1101). Content editing already rides `crdt_msg` via the Y.Text binding;
 * this is only genesis + delete.
 *
 * Functions take the channel as an argument (null when the room is not joined)
 * so they stay pure and unit-testable; `channel.ts` supplies the live singleton.
 */

interface PushReceiver<TOk = unknown> {
	receive(status: "ok", cb: (resp: TOk) => void): PushReceiver<TOk>;
	receive(status: "error" | "timeout", cb: (resp?: unknown) => void): PushReceiver<TOk>;
}

function reasonOf(resp: unknown): string {
	if (resp && typeof resp === "object" && "reason" in resp) {
		return String(resp.reason);
	}
	return "unknown";
}

export interface PushChannel {
	// The reply shape is the caller's claim about a server event it named — the
	// wire carries no type. Declaring it here keeps that claim in ONE place
	// instead of an `as T` at every await site.
	push<TOk = unknown>(event: string, payload: unknown): PushReceiver<TOk>;
}

/**
 * A CRDT op that did not succeed. `reason` is the server's error reason
 * (`notes_cap_reached`, `create_failed`, `recently_deleted`, `bad_path`,
 * `rate_limited`, …), or the synthetic `disconnected` (room not joined) /
 * `timeout`. Callers branch on `reason`; the message stays human-readable.
 */
export class CrdtOpError extends Error {
	constructor(
		readonly reason: string,
		readonly event: string,
	) {
		super(`crdt op ${event} failed: ${reason}`);
		this.name = "CrdtOpError";
	}
}

/**
 * Push a request frame and resolve on the server's `ok` reply. Rejects on an
 * `error` reply (message carries the server `reason`), on `timeout`, or when the
 * channel is null — i.e. the crdt room is not joined (offline). Phoenix's own
 * push timeout drives the `timeout` branch, so there is no timer to manage here.
 */
export function pushRequest<T = unknown>(
	channel: PushChannel | null,
	event: string,
	payload: unknown,
): Promise<T> {
	if (!channel) {
		return Promise.reject(new CrdtOpError("disconnected", event));
	}
	return new Promise<T>((resolve, reject) => {
		channel
			.push<T>(event, payload)
			.receive("ok", (resp) => resolve(resp))
			.receive("error", (resp) => reject(new CrdtOpError(reasonOf(resp), event)))
			.receive("timeout", () => reject(new CrdtOpError("timeout", event)));
	});
}

/**
 * Genesis a note row. Returns the server's AUTHORITATIVE doc_id: on ADOPT (the
 * path is already owned by a different live note) the server returns a DIFFERENT
 * id, and the caller must use it, not the minted one.
 */
export async function sendCrdtCreate(
	channel: PushChannel | null,
	docId: string,
	path: string,
): Promise<string> {
	const res = await pushRequest<{ doc_id: string }>(channel, "crdt_create", {
		doc_id: docId,
		path,
	});
	return res.doc_id;
}

/** What the server did with a genesis `b64`, verbatim from the reply.
 *  `stored` is the ONLY outcome that means the body is durably readable —
 *  `absent` (nothing seeded, the row is empty) and `occupied` (the row holds
 *  another lineage's body) both mean our content did not land. */
export type GenesisOutcome = "stored" | "absent" | "occupied";

export interface CrdtCreateWithContentResult {
	doc_id: string;
	genesis: GenesisOutcome;
}

/** Genesis a note row AND seed its body in one round trip. Same frame as
 *  `sendCrdtCreate`, plus the `b64` genesis update the server applies
 *  roomlessly. */
export function sendCrdtCreateWithContent(
	channel: PushChannel | null,
	docId: string,
	path: string,
	b64: string,
): Promise<CrdtCreateWithContentResult> {
	return pushRequest<CrdtCreateWithContentResult>(channel, "crdt_create", {
		doc_id: docId,
		path,
		b64,
	});
}

/** Delete a note by id, awaiting the server ack (idempotent — resolves even if
 *  the note was already gone). */
export function sendCrdtDelete(
	channel: PushChannel | null,
	docId: string,
): Promise<{ doc_id: string }> {
	return pushRequest<{ doc_id: string }>(channel, "crdt_delete", { doc_id: docId });
}
