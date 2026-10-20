// Server capabilities advertised on the sync channel's join reply. A
// self-hosted backend can be older than this app, so a new wire shape is used
// only once the server says it takes it.
let partSize: number | null = null;

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
}

/** Part size when attachments can be uploaded in parts, else null. */
export function attachmentPartSize(): number | null {
	return partSize;
}

/** Test seam. */
export function resetServerFeatures(): void {
	partSize = null;
}
