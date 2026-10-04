import { getActiveVaultId } from "../api/active-vault";
import { api } from "../api/client";
import { encodePathSegments } from "../lib/path";

// Object URLs by attachment path, for the life of the page. The editor remounts
// an embed widget whenever it scrolls back into view, and each remount would
// otherwise refetch the bytes.
//
// ponytail: never revoked, so every embedded image stays in memory until reload.
// Add an LRU with revokeObjectURL if long sessions with many large images hurt.
//
// Keyed by vault AND path: the same path in two vaults is two files. Cleared on a
// user change (see clearAttachmentUrls), because these are one user's private bytes.
const cache = new Map<string, Promise<string>>();

/** Drop every cached image and release its object URL. Call when the signed-in user changes. */
export function clearAttachmentUrls(): void {
	for (const url of cache.values()) {
		url.then((u) => URL.revokeObjectURL(u)).catch(() => undefined);
	}
	cache.clear();
}

export function loadAttachmentUrl(path: string): Promise<string> {
	const key = `${getActiveVaultId() ?? ""}:${path}`;
	let hit = cache.get(key);
	if (!hit) {
		hit = api
			.getBlob(`/attachments/${encodePathSegments(path)}?raw=1`)
			.then((blob) => URL.createObjectURL(blob));
		// A failure must not be cached: the file may exist once storage recovers.
		hit.catch(() => cache.delete(key));
		cache.set(key, hit);
	}
	return hit;
}

/** `![[target]]` to a vault path: exact path first, then a bare file name (Obsidian-style). */
export function resolveAttachmentTarget(
	attachments: { path: string }[],
	target: string,
): string | null {
	const exact = attachments.find((a) => a.path === target);
	if (exact) {
		return exact.path;
	}
	return attachments.find((a) => a.path.split("/").pop() === target)?.path ?? null;
}

/** A root-level file name not yet taken: `pic.png` -> `pic 1.png` -> `pic 2.png` (Obsidian-style). */
export function uniqueAttachmentName(attachments: { path: string }[], name: string): string {
	const taken = new Set(attachments.map((a) => a.path));
	if (!taken.has(name)) {
		return name;
	}
	const dot = name.lastIndexOf(".");
	const [stem, ext] = dot > 0 ? [name.slice(0, dot), name.slice(dot)] : [name, ""];
	for (let n = 1; ; n++) {
		const candidate = `${stem} ${n}${ext}`;
		if (!taken.has(candidate)) {
			return candidate;
		}
	}
}
