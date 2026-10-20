import { ApiError, api, LimitExceededError } from "./client";
import type { AttachmentSummary } from "./queries";

const MAX_RETRIES = 3;

interface Opts {
	onProgress?: (done: number, total: number) => void;
	signal?: AbortSignal;
	/** First retry delay; doubles per attempt. A 503 `retry-after` wins. */
	backoffMs?: number;
}

/** 4xx means the request itself is wrong, so resending cannot help. Network
 *  errors (TypeError), 5xx, 408 and 429 are transient. */
function isTerminal(err: unknown): boolean {
	if (err instanceof Error && err.name === "AbortError") {
		return true;
	}
	if (err instanceof Error && err.name === "LimitExceededError") {
		return true;
	}
	return (
		err instanceof ApiError &&
		err.status >= 400 &&
		err.status < 500 &&
		err.status !== 408 &&
		err.status !== 429
	);
}

function delayFor(err: unknown, attempt: number, backoffMs: number): number {
	if (err instanceof ApiError && err.retryAfterS !== undefined) {
		return err.retryAfterS * 1000;
	}
	return backoffMs * 2 ** attempt;
}

/** A backoff wait that ends the moment the caller aborts. */
function sleep(ms: number, signal?: AbortSignal): Promise<void> {
	return new Promise((resolve, reject) => {
		if (signal?.aborted) {
			reject(new DOMException("aborted", "AbortError"));
			return;
		}
		const onAbort = () => {
			clearTimeout(timer);
			reject(new DOMException("aborted", "AbortError"));
		};
		const timer = setTimeout(() => {
			signal?.removeEventListener("abort", onAbort);
			resolve();
		}, ms);
		signal?.addEventListener("abort", onAbort, { once: true });
	});
}

/**
 * Upload `file` through the resumable parts protocol. The server picks the part
 * size. Every request retries transient failures (3 times, backing off). After a
 * failed part or a failed complete the server is asked which parts it holds, so
 * only missing parts are sent again. Complete is idempotent on the server: a
 * status that says `completed` resolves with one more complete. A failure drops
 * the server session, best effort, except when a complete attempt may have
 * committed (outcome unknown).
 */
export async function uploadInParts(
	file: File,
	path: string,
	opts: Opts = {},
): Promise<{ attachment: AttachmentSummary }> {
	const { onProgress, signal, backoffMs = 500 } = opts;
	const { upload_id, part_size, part_count } = await api.post<{
		upload_id: string;
		part_size: number;
		part_count: number;
	}>(
		"/attachment-uploads",
		{
			path,
			size_bytes: file.size,
			mtime: Math.floor(file.lastModified / 1000),
			mime_type: file.type || undefined,
		},
		{ signal },
	);
	const base = `/attachment-uploads/${upload_id}`;
	let completeOutcomeUnknown = false;

	/** Wait out a retryable failure, or rethrow when it is terminal or retries ran out. */
	async function backOff(err: unknown, attempt: number, terminal = isTerminal): Promise<void> {
		if (terminal(err) || attempt >= MAX_RETRIES) {
			throw err;
		}
		await sleep(delayFor(err, attempt, backoffMs), signal);
	}

	/** `completed`: complete already committed; complete again returns the attachment. */
	async function status(): Promise<{ done: number[]; completed?: boolean }> {
		for (let attempt = 0; ; attempt++) {
			try {
				return await api.get<{ done: number[]; completed?: boolean }>(base);
			} catch (err) {
				await backOff(err, attempt);
			}
		}
	}

	async function putPart(n: number): Promise<void> {
		const body = file.slice((n - 1) * part_size, n * part_size);
		for (let attempt = 0; ; attempt++) {
			try {
				await api.putRaw(`${base}/parts/${n}`, body, { signal });
				return;
			} catch (err) {
				await backOff(err, attempt);
				if ((await status()).done.includes(n)) {
					return;
				}
			}
		}
	}

	// 409 missing_parts is the one 4xx that resending fixes.
	const isMissingParts = (err: unknown) => err instanceof ApiError && err.status === 409;
	const isNotFound = (err: unknown) => err instanceof ApiError && err.status === 404;
	const terminalOnComplete = (err: unknown) => isTerminal(err) && !isMissingParts(err);
	const postComplete = () =>
		api.post<{ attachment: AttachmentSummary }>(`${base}/complete`, undefined, { signal });

	async function complete(): Promise<{ attachment: AttachmentSummary }> {
		// Sticky: an attempt that ended with no answer may still be committing
		// on the server after a later status check said the session was open.
		let earlierAttemptUnanswered = false;
		for (let attempt = 0; ; attempt++) {
			try {
				return await postComplete();
			} catch (err) {
				// A refusal with a status proves nothing committed; anything else may have.
				completeOutcomeUnknown = !(err instanceof ApiError || err instanceof LimitExceededError);
				// A 404 after an attempt that may have committed is not a verdict
				// yet: one final status check below decides.
				if (earlierAttemptUnanswered && isNotFound(err)) {
					earlierAttemptUnanswered = false;
				} else {
					earlierAttemptUnanswered ||= completeOutcomeUnknown;
					await backOff(err, attempt, terminalOnComplete);
				}
				const { done, completed } = await status();
				// Committed (perhaps by an attempt whose response was lost): a
				// repeat complete returns the attachment.
				if (completed) {
					return await postComplete();
				}
				// The session answered open, so complete did not commit it.
				completeOutcomeUnknown = false;
				for (let n = 1; n <= part_count; n++) {
					if (!done.includes(n)) {
						await putPart(n);
					}
				}
			}
		}
	}

	try {
		for (let n = 1; n <= part_count; n++) {
			await putPart(n);
			onProgress?.(Math.min(n * part_size, file.size), file.size);
		}
		return await complete();
	} catch (err) {
		if (!completeOutcomeUnknown) {
			// The original error is what the caller needs; a failed cleanup must not replace it.
			await api.del(base).catch(() => undefined);
		}
		throw err;
	}
}
