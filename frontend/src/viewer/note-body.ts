import { splitFrontmatter } from "../crdt/frontmatter-codec";

// Sentinel marks images rewritten from Obsidian `![[X]]` embed syntax. The
// img component reads it and fetches via the authenticated attachments API.
const ATTACHMENT_SCHEME = "engram-attachment:";

function rewriteEmbeds(raw: string): string {
	return raw.replace(/!\[\[(?<inner>[^\]]+)\]\]/gu, (_match, inner: string) => {
		const [path, alias] = inner.split("|").map((s) => s.trim());
		return `![${alias ?? path}](${ATTACHMENT_SCHEME}${path})`;
	});
}

// The markdown NoteView renders: frontmatter removed, embeds rewritten.
// Frontmatter goes through the same splitter the CRDT codec uses, which only
// recognises a bare `---` fence. gray-matter (used before) treated `---js` as
// a JavaScript block and ran it through eval, on content any MCP agent or
// shared vault can write. CRLF is normalised first; the renderer treats both
// line endings alike.
export function noteBody(content: string): string {
	return rewriteEmbeds(splitFrontmatter(content.replace(/\r\n/g, "\n")).body);
}

export { ATTACHMENT_SCHEME };
