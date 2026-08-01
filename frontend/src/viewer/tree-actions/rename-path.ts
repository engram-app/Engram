/**
 * Swap the last path segment's BASE name (leaf minus extension) for
 * `newBaseName`, always re-attaching the original extension.
 *
 * Every rename surface — the tree and the note header — edits the DISPLAY name,
 * which never shows an extension. So the user has no way to express a file-type
 * change, and a dotted title like "Node.js guide" needs no disambiguation: the
 * dot is title text, always.
 *
 * Re-attaching unconditionally is also what keeps a note inside the CRDT doc's
 * `.endsWith(".md")` gate. A path that loses its extension — via a paste, or a
 * programmatic value replacement like Playwright's `.fill` — would strand the
 * editor on "Connecting…" forever.
 */
export function renameBaseName(oldPath: string, newBaseName: string): string {
	const parts = oldPath.split("/");
	const oldLeaf = parts.pop() ?? "";
	const dot = oldLeaf.lastIndexOf(".");
	parts.push(dot > 0 ? `${newBaseName}${oldLeaf.slice(dot)}` : newBaseName);
	return parts.join("/");
}
