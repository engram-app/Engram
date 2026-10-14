import { describe, expect, it } from "vitest";
import { initialScripts, overBudget } from "./bundle-budget";

const HTML = `<!doctype html><html><head>
<script type="module" crossorigin src="/assets/index-abc.js"></script>
<link rel="modulepreload" crossorigin href="/assets/react-dom-1.js">
<link rel="modulepreload" crossorigin href="/assets/hooks-2.js">
<link rel="stylesheet" crossorigin href="/assets/index-3.css">
</head><body><div id="root"></div></body></html>`;

describe("initialScripts", () => {
	// What the browser must fetch and run before the app can start: the entry
	// module and every chunk index.html preloads with it. Not lazy chunks, not CSS.
	it("is the entry module plus its modulepreloads", () => {
		expect(initialScripts(HTML)).toEqual(["index-abc.js", "react-dom-1.js", "hooks-2.js"]);
	});

	it("refuses an index.html with no entry module", () => {
		expect(() => initialScripts("<html></html>")).toThrow(/entry/u);
	});
});

describe("overBudget", () => {
	it("passes at or under the budget and fails over it", () => {
		expect(overBudget(200 * 1024, 200)).toBe(false);
		expect(overBudget(200 * 1024 + 1, 200)).toBe(true);
	});
});
