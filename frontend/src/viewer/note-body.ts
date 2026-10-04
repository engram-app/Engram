import { splitFrontmatter } from "../crdt/frontmatter-codec";

// Sentinel marks images rewritten from Obsidian `![[X]]` embed syntax. The
// img component reads it and fetches via the authenticated attachments API.
const ATTACHMENT_SCHEME = "engram-attachment:";

interface MdNode {
	type: string;
	value?: string;
	url?: string;
	alt?: string;
	data?: { hProperties: { src: string } };
	children?: MdNode[];
}

const EMBED = /!\[\[(?<inner>[^\]]+)\]\]/gu;

function splitEmbeds(text: string): MdNode[] {
	const out: MdNode[] = [];
	let last = 0;
	for (const m of text.matchAll(EMBED)) {
		const [path = "", alias] = (m.groups?.inner ?? "").split("|").map((s) => s.trim());
		if (m.index > last) {
			out.push({ type: "text", value: text.slice(last, m.index) });
		}
		// hProperties.src overrides the url mdast-util-to-hast percent-encodes,
		// so the img component gets the vault path byte for byte.
		const src = `${ATTACHMENT_SCHEME}${path}`;
		out.push({ type: "image", url: src, alt: alias || path, data: { hProperties: { src } } });
		last = m.index + m[0].length;
	}
	if (last < text.length) {
		out.push({ type: "text", value: text.slice(last) });
	}
	return out;
}

// Turns Obsidian `![[path|alias]]` into an attachment image. micromark reads
// `![` as an image start, so remark-wiki-link never sees an embed and it
// survives parsing as plain text. Rewriting `text` nodes (not the raw
// markdown) leaves code and inline code alone, and the path never goes back
// through the markdown parser, so spaces and parentheses stay intact.
function remarkEmbeds() {
	const visit = (node: MdNode): void => {
		if (!node.children) {
			return;
		}
		node.children = node.children.flatMap((child) =>
			child.type === "text" && child.value?.includes("![[") ? splitEmbeds(child.value) : [child],
		);
		for (const child of node.children) {
			visit(child);
		}
	};
	return visit;
}

// The markdown NoteView renders: frontmatter removed. Frontmatter goes
// through the same splitter the CRDT codec uses, which only recognises a bare
// `---` fence. gray-matter (used before) treated `---js` as a JavaScript block
// and ran it through eval, on content any MCP agent or shared vault can
// write. CRLF is normalised first; the renderer treats both line endings
// alike.
function noteBody(content: string): string {
	return splitFrontmatter(content.replace(/\r\n/g, "\n")).body;
}

export { ATTACHMENT_SCHEME, noteBody, remarkEmbeds };
