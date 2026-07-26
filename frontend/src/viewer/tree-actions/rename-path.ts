// Leaf-name rename → full path. Shared by the folder tree's inline rename and
// the note header's inline rename so the two entry points can't drift.

// RenameInput's caret selection only spans the basename (up to the
// extension dot) so a normal type-over-selection edit leaves the extension
// intact. That's a UX convenience, not a guarantee: a select-all, paste, or
// programmatic value replacement (e.g. Playwright's `.fill`) bypasses the
// selection and can hand back a bare name with no extension at all, or a
// dotted TITLE (e.g. "meeting v1.2", "Node.js guide") that isn't actually an
// extension change. Without this guard the note/attachment gets renamed to a
// path that doesn't end in the original extension server-side. For a note
// that silently breaks the CRDT doc's `.endsWith(".md")` gate on next open,
// stranding the editor on "Connecting…" forever.
//
// Rule: preserve the original extension unless newName ends with it already,
// or explicitly ends with a recognized note extension (a deliberate swap,
// e.g. .md -> .canvas). Otherwise the trailing dot(s) in newName are part of
// the title, not an extension, so the original extension is re-appended.
// ponytail: known ceiling, an attachment ext-swap like ("a.png","a.jpg")
// becomes "a.jpg.png" since .jpg isn't in the recognized list. Inline rename
// isn't the intended path for changing a file's type; add a MIME allowlist
// only if that becomes a real complaint.
const RECOGNIZED_NOTE_EXTENSIONS = [".md", ".canvas"];

export function withPreservedExtension(oldLeaf: string, newName: string): string {
	const dot = oldLeaf.lastIndexOf(".");
	const origExt = dot > 0 ? oldLeaf.slice(dot) : "";
	const lowerNewName = newName.toLowerCase();
	if (origExt && lowerNewName.endsWith(origExt.toLowerCase())) {
		return newName;
	}
	if (RECOGNIZED_NOTE_EXTENSIONS.some((ext) => lowerNewName.endsWith(ext))) {
		return newName;
	}
	return origExt ? `${newName}${origExt}` : newName;
}

/** Swap the last path segment for `newName`, keeping the folder + extension. */
export function renamePathLeaf(oldPath: string, newName: string): string {
	const parts = oldPath.split("/");
	const oldLeaf = parts.pop() ?? "";
	parts.push(withPreservedExtension(oldLeaf, newName));
	return parts.join("/");
}
