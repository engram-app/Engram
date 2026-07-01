import { describe, expect, it } from "vitest";
import { collideBump } from "./collide-bump";

describe("collideBump", () => {
	it("returns the base name when no conflicts", () => {
		expect(collideBump(new Set(), "Untitled.md")).toBe("Untitled.md");
	});

	it('appends " 1" before extension on first conflict', () => {
		expect(collideBump(new Set(["Untitled.md"]), "Untitled.md")).toBe("Untitled 1.md");
	});

	it("skips taken numbers to find the lowest free slot", () => {
		expect(
			collideBump(new Set(["Untitled.md", "Untitled 1.md", "Untitled 3.md"]), "Untitled.md"),
		).toBe("Untitled 2.md");
	});

	it("handles names without an extension (folders)", () => {
		expect(collideBump(new Set(["Untitled folder"]), "Untitled folder")).toBe("Untitled folder 1");
	});

	it("caps the search at 1000 iterations and throws past the cap", () => {
		const huge = new Set(
			Array.from({ length: 1001 }, (_, i) => (i === 0 ? "Untitled.md" : `Untitled ${i}.md`)),
		);
		expect(() => collideBump(huge, "Untitled.md", { cap: 1000 })).toThrow(/too many collisions/i);
	});
});
