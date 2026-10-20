import { ApiError, api } from "./client";
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

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Upload `file` through the resumable parts protocol. The server picks the part
 * size. A failed part is retried (3 times, backing off) after asking the server
 * which parts it holds, so a part that landed before the connection dropped is
 * not sent again. Any failure drops the server session, best effort.
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

	async function putPart(n: number): Promise<void> {
		const body = file.slice((n - 1) * part_size, n * part_size);
		for (let attempt = 0; ; attempt++) {
			try {
				await api.putRaw(`${base}/parts/${n}`, body, { signal });
				return;
			} catch (err) {
				if (isTerminal(err) || attempt >= MAX_RETRIES) {
					throw err;
				}
				await sleep(delayFor(err, attempt, backoffMs));
				const { done } = await api.get<{ done: number[] }>(base);
				if (done.includes(n)) {
					return;
				}
			}
		}
	}

	try {
		for (let n = 1; n <= part_count; n++) {
			await putPart(n);
			onProgress?.(Math.min(n * part_size, file.size), file.size);
		}
		return await api.post<{ attachment: AttachmentSummary }>(`${base}/complete`, undefined, {
			signal,
		});
	} catch (err) {
		// The original error is what the caller needs; a failed cleanup must not replace it.
		await api.del(base).catch(() => undefined);
		throw err;
	}
}
