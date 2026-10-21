import { LimitExceededError } from "@/api/client";
import { isBlockedFileName } from "@/api/server-features";
import type { Translate } from "@/i18n/translate";
import { notify } from "@/lib/notify";
import { uniqueAttachmentName } from "../attachment-blob";
import { uploadFailure } from "./upload-failure";

// Paths this tab has just uploaded. The attachments list only learns about them
// after the upload's refetch lands, and the backend upserts, so a second drop of
// the same name inside that window would silently replace the first. Entries expire
// once the list has had time to catch up.
const RESERVE_MS = 30_000;
const reserved = new Map<string, number>();

function reservedPaths(now: number): { path: string }[] {
	for (const [path, at] of reserved) {
		if (now - at > RESERVE_MS) {
			reserved.delete(path);
		}
	}
	return [...reserved.keys()].map((path) => ({ path }));
}

type Upload = (body: { path: string; file: File }) => Promise<unknown>;

/**
 * Upload files straight into `folder` ("" = vault root), no dialog. A name that
 * is already taken gets a suffix so a drop never overwrites. Files go one at a
 * time and one failure does not stop the rest. Returns the vault paths that made
 * it, in order. A plan-limit error already opened the upgrade dialog (api/client),
 * so it gets no toast of its own.
 */
/**
 * `| # ^ [ ]` cannot appear in a wikilink target, so a file called `shot #2.png`
 * would produce an embed that points at nothing. Obsidian replaces them on import;
 * so do we.
 */
function safeName(name: string): string {
	return name.replace(/[|#^[\]]/gu, "-");
}

export async function uploadFilesTo(opts: {
	upload: Upload;
	existing: { path: string }[];
	files: File[];
	folder: string;
	/** The caller's translate function (`useT()`). */
	t: Translate;
}): Promise<string[]> {
	const { t } = opts;
	const done: string[] = [];
	for (const file of opts.files) {
		const path = claimUploadPath(opts.existing, opts.folder, file.name);
		try {
			await opts.upload({ path, file });
			done.push(path);
		} catch (err) {
			if (!(err instanceof LimitExceededError)) {
				notify.error(
					t("{name}: {reason}", { name: file.name, reason: uploadFailure(err, t).text }),
				);
			}
		}
	}
	return done;
}

/**
 * Drop the files the server would refuse as executables, with one toast each,
 * BEFORE any dialog or request: picking an AppImage must not walk the user
 * through choosing a folder only to fail at Upload.
 */
export function withoutBlocked(files: File[], t: Translate): File[] {
	return files.filter((file) => {
		if (!isBlockedFileName(file.name)) {
			return true;
		}
		notify.error(
			t("{name}: {reason}", { name: file.name, reason: t("Executable files don't sync.") }),
		);
		return false;
	});
}

/**
 * The vault path a new upload of `fileName` into `folder` ("" = root) goes to,
 * reserved so the next claim in this tab cannot pick it too. A taken name gets
 * a number ("song 1.flac"), the way Obsidian names a duplicate, because the
 * server UPSERTS by path: reusing a name silently replaces that file. The one
 * rule for every upload path (drop, Upload dialog).
 */
export function claimUploadPath(
	existing: readonly { path: string }[],
	folder: string,
	fileName: string,
): string {
	const taken = [...existing, ...reservedPaths(Date.now())];
	// Names are unique per folder, so compare against this folder's files only.
	const prefix = folder ? `${folder}/` : "";
	const inFolder = taken
		.filter((a) => a.path.startsWith(prefix) && !a.path.slice(prefix.length).includes("/"))
		.map((a) => ({ path: a.path.slice(prefix.length) }));
	const name = uniqueAttachmentName(inFolder, safeName(fileName));
	const path = folder ? `${folder}/${name}` : name;
	reserved.set(path, Date.now());
	return path;
}

/** Test seam: forget every reservation. */
export function resetReservedPaths(): void {
	reserved.clear();
}
