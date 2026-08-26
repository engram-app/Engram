/**
 * The `send` function for the durable CrdtOpQueue: dispatches a held CRDT op
 * (create / delete) over the current channel and maps the outcome to the
 * queue's tri-state result. Mirrors the plugin's `crdt-op-dispatch.ts` error
 * taxonomy exactly (issue #1030) so the two interfaces retry/drop identically.
 *
 * Pure aside from the injected `channel()` / hooks, so the taxonomy is
 * unit-testable without a real socket.
 *
 * Error taxonomy (backend reasons from crdt_channel.ex):
 *  - server ok                       → "ok"  (delivered; queue drops it)
 *  - RETRYABLE reject                → "error" / "timeout" (queue retries):
 *      rate_limited, recently_deleted (delete-wins window), the synthetic
 *      `disconnected` (no socket), any unstructured failure; a timeout.
 *  - LIMIT reject                    → "error" (RETRYABLE) AND routed through
 *      onLimit so the user is TOLD once: notes_cap_reached is a transient plan
 *      cap that self-delivers once the user frees a note / upgrades.
 *  - TERMINAL reject                 → "ok" to REMOVE it (retrying cannot help)
 *      BUT routed through onTerminal so it is logged, never silently vanished:
 *      id_conflict, version_conflict, bad_doc_id, implausible_state_vector.
 *
 * A stuck retryable/limit op is still bounded: the queue drops it after
 * MAX_ATTEMPTS or OP_TTL_MS, so nothing retries forever.
 */

import { CrdtOpError } from "../api/crdt-ops";
import type { CrdtOp, SendResult } from "./op-queue";

/** Server reasons where a retry cannot succeed. Remove the op (surfaced). */
export const TERMINAL_REASONS: ReadonlySet<string> = new Set([
	"id_conflict",
	"version_conflict",
	"bad_doc_id",
	"implausible_state_vector",
]);

/** Server reasons that are TRANSIENT plan limits: the user can clear them (free
 *  a note, upgrade). Retry (bounded) AND surface to the user, never drop after
 *  one attempt like a terminal reason. */
export const LIMIT_REASONS: ReadonlySet<string> = new Set(["notes_cap_reached"]);

/** The two acked socket calls the queue dispatches over. `docId → serverId`
 *  for create (the authoritative id, DIFFERENT on adopt); delete just acks. */
export interface CrdtOpChannel {
	crdtCreate(docId: string, path: string): Promise<string>;
	crdtDelete(docId: string): Promise<{ doc_id: string }>;
}

export interface CrdtSendHooks {
	/** The current channel, or null when no socket is up (→ hold + retry). */
	channel: () => CrdtOpChannel | null;
	/** A create acked: serverId is AUTHORITATIVE (differs on ADOPT). Resolves the
	 *  caller's promise + remaps the cache id. A throw here is swallowed — the
	 *  row already exists, the create must not retry. */
	onCreated: (localId: string, serverId: string, path: string) => void | Promise<void>;
	/** A delete acked. Resolves the caller's promise. */
	onDeleted?: (docId: string) => void;
	/** A terminally-failed op about to be dropped. Surface it (error log). */
	onTerminal: (op: CrdtOp, reason: string) => void;
	/** A retryable PLAN-LIMIT reject (e.g. notes_cap_reached). Surface once (toast);
	 *  the op is still retried (bounded) so it delivers once the cap clears. */
	onLimit?: (op: CrdtOp, reason: string) => void;
}

/** The server `reason` from a rejection, or null for an unstructured failure. */
export function crdtOpFailureReason(err: unknown): string | null {
	return err instanceof CrdtOpError ? err.reason : null;
}

/** Build the queue's `send`. */
export function makeCrdtOpSend(hooks: CrdtSendHooks): (op: CrdtOp) => Promise<SendResult> {
	// Surface each op's limit block ONCE: the queue retries it on backoff up to
	// MAX_ATTEMPTS, and a toast per retry would spam the user.
	const limitSurfaced = new Set<string>();
	return async (op) => {
		const ch = hooks.channel();
		if (!ch) {
			return "error"; // no socket yet — hold and retry on the next tick
		}
		try {
			if (op.kind === "create") {
				const { payload } = op;
				const path =
					typeof payload === "object" &&
					payload !== null &&
					"path" in payload &&
					typeof payload.path === "string"
						? payload.path
						: "";
				const serverId = await ch.crdtCreate(op.docId, path);
				try {
					await hooks.onCreated(op.docId, serverId, path);
				} catch {
					// crdtCreate already ACKED: the row exists (possibly remapped). A
					// post-ack step throwing must NOT retry the create — that would
					// duplicate/misroute the row. The body self-heals on the next edit.
				}
			} else {
				await ch.crdtDelete(op.docId);
				hooks.onDeleted?.(op.docId);
			}
			return "ok";
		} catch (err) {
			const reason = crdtOpFailureReason(err);
			if (reason && LIMIT_REASONS.has(reason)) {
				if (!limitSurfaced.has(op.id)) {
					limitSurfaced.add(op.id);
					hooks.onLimit?.(op, reason); // tell the user, once
				}
				return "error"; // RETRYABLE (bounded): the cap clears when a note is freed
			}
			if (reason && TERMINAL_REASONS.has(reason)) {
				hooks.onTerminal(op, reason); // must not vanish; must not retry forever
				return "ok"; // remove from the queue
			}
			return reason === "timeout" ? "timeout" : "error";
		}
	};
}
