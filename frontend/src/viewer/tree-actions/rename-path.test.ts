import { describe, expect, it } from "vitest";
import { renameBaseName } from "./rename-path";

describe("renameBaseName", () => {
	it("re-attaches the original extension to a bare title", () => {
		expect(renameBaseName("a/Child.md", "renamed")).toBe("a/renamed.md");
	});

	it("treats a dot in the new name as title text, not an extension", () => {
		expect(renameBaseName("a/Child.md", "meeting v1.2")).toBe("a/meeting v1.2.md");
		expect(renameBaseName("a/Child.md", "Node.js guide")).toBe("a/Node.js guide.md");
	});

	// The rename box never shows an extension, so a typed one can only be part
	// of the title. Honouring it as a type change would let a note leave the
	// CRDT `.md` gate from a surface that never offered the choice.
	it("does not let a typed extension change the file type", () => {
		expect(renameBaseName("a/Child.md", "board.canvas")).toBe("a/board.canvas.md");
		expect(renameBaseName("a/Child.md", "renamed.md")).toBe("a/renamed.md.md");
	});

	it("preserves a non-markdown extension", () => {
		expect(renameBaseName("a/diagram.canvas", "flow v2")).toBe("a/flow v2.canvas");
		expect(renameBaseName("assets/photo.png", "vacation")).toBe("assets/vacation.png");
	});

	it("keeps the folder untouched, including nested ones", () => {
		expect(renameBaseName("a/b/c/note.md", "renamed")).toBe("a/b/c/renamed.md");
		expect(renameBaseName("note.md", "renamed")).toBe("renamed.md");
	});

	it("leaves an extension-less leaf extension-less", () => {
		expect(renameBaseName("a/README", "readme")).toBe("a/readme");
	});

	// A leading dot is the whole name (".gitignore"), not an extension — the
	// `dot > 0` guard keeps it from being split into "" + ".gitignore".
	it("treats a dotfile leaf as a name, not an extension", () => {
		expect(renameBaseName("a/.gitignore", "renamed")).toBe("a/renamed");
	});
});
