import { describe, expect, it } from "vitest";
import { noteName } from "./note-name";

describe("noteName", () => {
	it("returns the filename without extension", () => {
		expect(noteName("folder/sub/My Note.md")).toBe("My Note");
	});

	it("handles root-level paths", () => {
		expect(noteName("Inbox.md")).toBe("Inbox");
	});

	it("strips non-md extensions too", () => {
		expect(noteName("boards/Plan.canvas")).toBe("Plan");
	});

	it("keeps dots inside the name", () => {
		expect(noteName("notes/v1.2 release.md")).toBe("v1.2 release");
	});

	it("does not treat a leading dot as an extension", () => {
		expect(noteName(".hidden")).toBe(".hidden");
	});

	it("returns extensionless names as-is", () => {
		expect(noteName("folder/README")).toBe("README");
	});

	it("returns empty string for empty path", () => {
		expect(noteName("")).toBe("");
	});
});
