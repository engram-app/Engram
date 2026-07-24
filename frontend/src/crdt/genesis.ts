import * as encoding from "lib0/encoding";
import * as syncProtocol from "y-protocols/sync";
import * as Y from "yjs";
import { parseFrontmatter, splitFrontmatter } from "./frontmatter-codec";
import { applyParsedFrontmatter } from "./frontmatter-doc";

/** Outer y-protocols message-type tag — we only speak `messageSync`. */
const MESSAGE_SYNC = 0;

function toB64(bytes: Uint8Array): string {
	return btoa(Array.from(bytes, (b) => String.fromCharCode(b)).join(""));
}

/**
 * Build the base64 `messageSync` update frame that seeds a brand-new note's
 * content in one `crdt_create_batch` entry (the web's create-with-content path,
 * e.g. duplicate + onboarding welcome-note — issue #1101).
 *
 * A note's Y.Doc holds the body in the `content` Y.Text and frontmatter in the
 * frontmatter maps, so a genesis doc is built from markdown with the SAME codec
 * the editor uses (splitFrontmatter → parseFrontmatter → applyParsedFrontmatter
 * + content insert), then its full state is wrapped as a messageSync update —
 * byte-identical to a live `crdt_msg` (CrdtChannel.sendUpdateRaw) and to the
 * plugin's batch-genesis frame, so the backend room applies it uniformly.
 */
export function buildGenesisFrame(markdown: string): string {
	const doc = new Y.Doc();
	const { fmBlock, body } = splitFrontmatter(markdown);
	const parsed = fmBlock === null ? { order: [], values: {} } : parseFrontmatter(fmBlock);
	doc.transact(() => {
		if (parsed === null) {
			// Malformed frontmatter YAML — don't drop it. Seed the whole markdown as
			// plain body so no content is lost (matches "keep raw" editor behavior
			// closely enough for a genesis; structured fm only applies to valid YAML).
			if (markdown.length > 0) {
				doc.getText("content").insert(0, markdown);
			}
		} else {
			if (body.length > 0) {
				doc.getText("content").insert(0, body);
			}
			applyParsedFrontmatter(doc, parsed);
		}
	});

	const encoder = encoding.createEncoder();
	encoding.writeVarUint(encoder, MESSAGE_SYNC);
	syncProtocol.writeUpdate(encoder, Y.encodeStateAsUpdate(doc));
	const frame = toB64(encoding.toUint8Array(encoder));
	doc.destroy();
	return frame;
}
