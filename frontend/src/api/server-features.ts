// Server capabilities advertised on the sync channel's join reply. A
// self-hosted backend can be older than this app, so a new wire shape is used
// only once the server says it takes it.
let partSize: number | null = null;
// Extensions the server refuses (".exe"). Empty until a join reply lists them,
// so an older server never makes the app refuse what it would accept.
let blocked = new Set<string>();

/** Record the features of a sync join reply. A reply without them (an older
 *  server) leaves the state as it was. */
export function captureServerFeatures(resp: unknown): void {
	const features =
		typeof resp === "object" && resp !== null && "features" in resp ? resp.features : undefined;
	if (typeof features !== "object" || features === null) {
		return;
	}
	const size = "attachment_part_size" in features ? features.attachment_part_size : undefined;
	const chunked = "chunked_attachment_upload" in features && features.chunked_attachment_upload;
	partSize = chunked === true && typeof size === "number" && size > 0 ? size : null;
	const list = "blocked_extensions" in features ? features.blocked_extensions : undefined;
	if (Array.isArray(list)) {
		blocked = new Set(list.filter((e): e is string => typeof e === "string"));
	}
}

/** Part size when attachments can be uploaded in parts, else null. */
export function attachmentPartSize(): number | null {
	return partSize;
}

/**
 * True when the server would refuse this file as an executable. Same rule as
 * the server's: trailing dots and spaces dropped (Windows does that on write),
 * then the last extension, case-insensitive. A dotfile has no extension.
 */
export function isBlockedFileName(name: string): boolean {
	const trimmed = name.replace(/[. ]+$/u, "");
	const dot = trimmed.lastIndexOf(".");
	return dot > 0 && blocked.has(trimmed.slice(dot).toLowerCase());
}

/** Test seam. */
export function resetServerFeatures(): void {
	partSize = null;
	blocked = new Set();
}
