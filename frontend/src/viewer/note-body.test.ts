import { describe, expect, test } from "vitest";
import { noteBody } from "./note-body";

describe("noteBody", () => {
	test("strips a YAML frontmatter block", () => {
		expect(noteBody("---\ntitle: A\n---\n# Body\n")).toBe("# Body\n");
	});

	test("strips a CRLF frontmatter block", () => {
		expect(noteBody("---\r\ntitle: A\r\n---\r\n# Body\r\n")).toBe("# Body\n");
	});

	// gray-matter ran a `---js` block through eval: note content is untrusted
	// (MCP agents, shared vaults), so a fence with a language tag must stay
	// plain text and never execute.
	test("never evaluates a ---js block, and leaves it in the body", () => {
		const g = globalThis as { pwned?: number };
		delete g.pwned;
		const body = noteBody("---js\n{a:(globalThis.pwned=1)}\n---\ntext\n");
		expect(g.pwned).toBeUndefined();
		expect(body).toContain("pwned");
	});

	test("a note without frontmatter passes through", () => {
		expect(noteBody("plain")).toBe("plain");
	});
});
