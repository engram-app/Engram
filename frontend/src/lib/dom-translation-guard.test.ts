import { describe, expect, it, vi } from "vitest";
import "./dom-translation-guard";

// Browser page translation (Google Translate, Chrome's built-in translate)
// swaps the text nodes React owns for its own <font> wrappers. React's next
// commit then removes or inserts relative to a node that is no longer where
// it left it, the DOM throws NotFoundError, and the user lands on the error
// page (Sentry ENGRAM-FRONTEND-4/-8/-9, ar and zh-CN users).
describe("DOM translation guard", () => {
	function translated() {
		const parent = document.createElement("p");
		const text = document.createTextNode("hello");
		parent.appendChild(text);
		// What a translator does: move React's node under its own wrapper.
		const font = document.createElement("font");
		parent.replaceChild(font, text);
		font.appendChild(text);
		return { parent, text, font };
	}

	it("removeChild of a node moved by a translator does not throw", () => {
		const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
		const { parent, text, font } = translated();

		expect(parent.removeChild(text)).toBe(text);
		expect(text.parentNode).toBe(font);
		expect(warn).toHaveBeenCalledTimes(1);
		warn.mockRestore();
	});

	it("insertBefore a reference node moved by a translator does not throw", () => {
		const warn = vi.spyOn(console, "warn").mockImplementation(() => undefined);
		const { parent, text } = translated();
		const inserted = document.createElement("span");

		expect(parent.insertBefore(inserted, text)).toBe(inserted);
		expect(warn).toHaveBeenCalledTimes(1);
		warn.mockRestore();
	});

	it("leaves normal removeChild and insertBefore unchanged", () => {
		const warn = vi.spyOn(console, "warn");
		const parent = document.createElement("div");
		const a = parent.appendChild(document.createElement("i"));
		const b = document.createElement("b");

		expect(parent.insertBefore(b, a)).toBe(b);
		expect([...parent.childNodes]).toEqual([b, a]);
		// A null reference node still means "append".
		const c = document.createElement("u");
		parent.insertBefore(c, null);
		expect(parent.lastChild).toBe(c);
		expect(parent.removeChild(a)).toBe(a);
		expect([...parent.childNodes]).toEqual([b, c]);
		expect(warn).not.toHaveBeenCalled();
		warn.mockRestore();
	});
});
