import { useQueryClient } from "@tanstack/react-query";
import { useParams } from "react-router";
import { useActiveVaultId } from "../api/active-vault";
import type { Note } from "../api/queries";

export function useActiveFolder(): string {
	const params = useParams();
	const id = params.id ?? null;
	const vaultId = useActiveVaultId();
	const qc = useQueryClient();
	if (id === null || id === "") {
		return "";
	}
	const note = qc.getQueryData<Note>(["note", vaultId, id]);
	const folder = note?.folder ?? "";
	if (folder === "") {
		return "";
	}
	// Guard against a deleted folder: the open note (and its cached `folder`)
	// can outlive the folder itself — you delete a folder while a note inside it
	// is open, the route still points at that note. Creating "in" that folder
	// would re-imply the path server-side and RESURRECT the folder. Only target
	// it if it still exists in the loaded folder list; otherwise fall back to
	// the vault root. When the list hasn't loaded yet (undefined) we trust the
	// note's folder — resetting on a load-race would misfile new items at root.
	//
	// Match EXACTLY: every folder level has its own marker row (Folder.name is
	// the full path), so an exact hit is sufficient. A prefix/ancestor match
	// would wrongly keep a deleted NESTED folder alive whenever a parent
	// survives (delete Projects/Draft, Projects stays → Draft resurrects).
	const data = qc.getQueryData<{ folders?: Array<{ name: string }> }>(["folders", vaultId]);
	if (data === undefined) {
		return folder;
	}
	const stillExists = data.folders?.some((f) => f.name === folder) ?? false;
	return stillExists ? folder : "";
}
