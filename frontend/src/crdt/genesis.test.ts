import * as decoding from "lib0/decoding";
import * as encoding from "lib0/encoding";
import { describe, expect, it } from "vitest";
import * as syncProtocol from "y-protocols/sync";
import * as Y from "yjs";
import { emitFrontmatterText } from "./frontmatter-doc";
import { buildGenesisFrame } from "./genesis";

const MESSAGE_SYNC = 0;

// Apply a genesis frame the same way the backend room does: decode the
// messageSync wrapper and fold the update into a fresh doc. Then reconstruct
// the note's markdown the way materialization does: frontmatter block + body.
function applyAndRead(frameB64: string): string {
	const doc = new Y.Doc();
	const bytes = Uint8Array.from(atob(frameB64), (c) => c.charCodeAt(0));
	const decoder = decoding.createDecoder(bytes);
	decoding.readVarUint(decoder); // skip the messageSync tag (asserted in its own test)
	const replyEncoder = encoding.createEncoder();
	encoding.writeVarUint(replyEncoder, MESSAGE_SYNC);
	syncProtocol.readSyncMessage(decoder, replyEncoder, doc, "test");
	return emitFrontmatterText(doc) + doc.getText("content").toString();
}

describe("buildGenesisFrame", () => {
	it("round-trips a plain body (no frontmatter)", () => {
		const md = "# Title\n\nsome body\nsecond line\n";
		expect(applyAndRead(buildGenesisFrame(md))).toBe(md);
	});

	it("round-trips body + frontmatter", () => {
		const md = "---\ntitle: Hi\ntags: a\n---\n# Body\ntext\n";
		// Codec normalizes frontmatter; assert the reconstruction is stable
		// (idempotent) rather than byte-identical to arbitrary input.
		const once = applyAndRead(buildGenesisFrame(md));
		const twice = applyAndRead(buildGenesisFrame(once));
		expect(twice).toBe(once);
		// Body survives verbatim after the frontmatter block.
		expect(once.endsWith("# Body\ntext\n")).toBe(true);
	});

	it("round-trips empty content", () => {
		expect(applyAndRead(buildGenesisFrame(""))).toBe("");
	});

	it("preserves malformed-frontmatter content as body (no data loss)", () => {
		const md = "---\na: [unclosed\n---\nbody here\n";
		expect(applyAndRead(buildGenesisFrame(md))).toBe(md);
	});

	it("produces a messageSync-wrapped update frame", () => {
		const bytes = Uint8Array.from(atob(buildGenesisFrame("x")), (c) => c.charCodeAt(0));
		expect(decoding.readVarUint(decoding.createDecoder(bytes))).toBe(MESSAGE_SYNC);
	});
});
