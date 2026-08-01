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

interface PushReceiver {
	receive(status: "ok" | "error" | "timeout", cb: (resp?: unknown) => void): PushReceiver;
}

function reasonOf(resp: unknown): string {
	if (resp && typeof resp === "object" && "reason" in resp) {
		return String((resp as { reason: unknown }).reason);
	}
	return "unknown";
}

export interface PushChannel {
	push(event: string, payload: unknown): PushReceiver;
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
			.push(event, payload)
			.receive("ok", (resp) => resolve(resp as T))
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

export interface CrdtCreateBatchResult {
	results: { doc_id: string; status: "ok" | "error"; reason?: string; limit?: number }[];
}

/** Batch genesis-with-content (server caps at 100 creates/request). */
export function sendCrdtCreateBatch(
	channel: PushChannel | null,
	creates: { doc_id: string; path: string; b64: string }[],
): Promise<CrdtCreateBatchResult> {
	return pushRequest<CrdtCreateBatchResult>(channel, "crdt_create_batch", { creates });
}

/** Delete a note by id, awaiting the server ack (idempotent — resolves even if
 *  the note was already gone). */
export function sendCrdtDelete(
	channel: PushChannel | null,
	docId: string,
): Promise<{ doc_id: string }> {
	return pushRequest<{ doc_id: string }>(channel, "crdt_delete", { doc_id: docId });
}
