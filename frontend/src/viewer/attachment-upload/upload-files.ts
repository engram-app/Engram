import { toast } from "sonner";
import { LimitExceededError } from "@/api/client";
import { englishT, type Translate } from "@/i18n/translate";
import { uniqueAttachmentName } from "../attachment-blob";
import { fileToBase64 } from "./file-to-base64";

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

type Upload = (body: {
	path: string;
	mime_type?: string;
	content_base64: string;
	mtime: number;
}) => Promise<unknown>;

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
	/** The caller's translate function (`useT()`); English when omitted. */
	t?: Translate;
}): Promise<string[]> {
	const t = opts.t ?? englishT;
	const taken = [...opts.existing, ...reservedPaths(Date.now())];
	const done: string[] = [];
	for (const file of opts.files) {
		// Names are unique per folder, so compare against this folder's files only.
		const prefix = opts.folder ? `${opts.folder}/` : "";
		const inFolder = taken
			.filter((a) => a.path.startsWith(prefix) && !a.path.slice(prefix.length).includes("/"))
			.map((a) => ({ path: a.path.slice(prefix.length) }));
		const name = uniqueAttachmentName(inFolder, safeName(file.name));
		const path = opts.folder ? `${opts.folder}/${name}` : name;
		reserved.set(path, Date.now());
		try {
			await opts.upload({
				path,
				mime_type: file.type || undefined,
				content_base64: await fileToBase64(file),
				mtime: Math.floor(file.lastModified / 1000),
			});
			taken.push({ path });
			done.push(path);
		} catch (err) {
			if (!(err instanceof LimitExceededError)) {
				toast.error(t("Couldn't upload {name}", { name: file.name }));
			}
		}
	}
	return done;
}
