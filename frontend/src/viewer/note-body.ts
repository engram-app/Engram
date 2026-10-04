// Sentinel marks images rewritten from Obsidian `![[X]]` embed syntax. The
// img component reads it and fetches via the authenticated attachments API.
const ATTACHMENT_SCHEME = "engram-attachment:";

// Marks an embed for the parser. micromark reads `![` as an image start, so
// remark-wiki-link never sees `![[x]]`, and emphasis, strikethrough, math and
// GFM autolinks then split its text before any tree plugin runs (`_draft_.png`
// lost its underscores). As `[[<EMBED>x]]` it is a wikilink, which
// remark-wiki-link takes as one token. U+E000 is private-use: no real text has
// it.
const EMBED = "";

// Frontmatter is cut, never parsed: gray-matter (used before) treated `---js`
// as a JavaScript block and ran it through eval, on content any MCP agent or
// shared vault can write. Matches what gray-matter hid: a leading BOM,
// trailing spaces on either fence, an empty block, no final newline.
const FRONTMATTER = /^﻿?---[ \t]*\n(?:[\s\S]*?\n)?---[ \t]*(?:\n|$)/u;

// The markdown NoteView renders: frontmatter removed, embeds marked for
// remarkEmbeds. CRLF is normalised first; the renderer treats both line
// endings alike.
function noteBody(content: string): string {
	return content.replace(/\r\n/g, "\n").replace(FRONTMATTER, "").replaceAll("![[", `[[${EMBED}`);
}

interface MdNode {
	type: string;
	value?: string;
	url?: string;
	alt?: string;
	data?: { alias?: string; hProperties?: { src: string } };
	children?: MdNode[];
}

// Turns marked wikilinks into attachment images, and puts `![[` back
// everywhere else the marker landed: code, math, raw HTML, or text the
// wikilink parser did not claim. Must run after remarkWikiLink.
function remarkEmbeds() {
	const visit = (node: MdNode): void => {
		if (node.type === "wikiLink" && node.value?.startsWith(EMBED)) {
			const path = node.value.slice(EMBED.length).trim();
			const alias = node.data?.alias?.trim();
			// hProperties.src overrides the url mdast-util-to-hast percent-encodes,
			// so the img component gets the vault path byte for byte.
			const src = `${ATTACHMENT_SCHEME}${path}`;
			node.type = "image";
			node.url = src;
			node.alt = alias && alias !== node.value.trim() ? alias : path;
			node.data = { hProperties: { src } };
			node.value = undefined;
			return;
		}
		if (typeof node.value === "string") {
			node.value = node.value.replaceAll(`[[${EMBED}`, "![[");
		}
		for (const child of node.children ?? []) {
			visit(child);
		}
	};
	return visit;
}

export { ATTACHMENT_SCHEME, noteBody, remarkEmbeds };
