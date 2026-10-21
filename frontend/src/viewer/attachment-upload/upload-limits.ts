// Plan limits checked BEFORE an upload, so a file that cannot fit is refused
// the moment it is picked or dropped, with the numbers, instead of after the
// user has chosen a folder and waited on a 402. Advisory: the server still
// enforces both limits, and its 402 remains the fallback (storage spread over
// several vaults is only partly visible here).

export interface UploadLimits {
	/** Per-file ceiling in bytes; null = none. */
	maxFileBytes: number | null;
	/** Attachment storage ceiling in bytes; null = none. */
	storageCap: number | null;
	/** Bytes already stored, as far as this client can see. */
	usedBytes: number;
}

/** What each paid plan allows (capabilities.plan_limits); null = no ceiling. */
export type PlanLimits = Partial<
	Record<"starter" | "pro", { max_file_bytes: number | null; attachment_bytes_cap: number | null }>
>;

export interface Screened {
	allowed: File[];
	/** Over the per-file limit. */
	tooLarge: File[];
	/** Would push storage past its cap. */
	noRoom: File[];
}

export function screenUploads(files: File[], limits: UploadLimits): Screened {
	const out: Screened = { allowed: [], tooLarge: [], noRoom: [] };
	let used = limits.usedBytes;
	for (const file of files) {
		if (limits.maxFileBytes !== null && file.size > limits.maxFileBytes) {
			out.tooLarge.push(file);
		} else if (limits.storageCap !== null && used + file.size > limits.storageCap) {
			out.noRoom.push(file);
		} else {
			used += file.size;
			out.allowed.push(file);
		}
	}
	return out;
}
