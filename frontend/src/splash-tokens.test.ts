import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

// index.html styles the boot splash inline, before any stylesheet arrives, with
// colours copied from main.css's tokens (it cannot read them: the stylesheet is
// what it paints ahead of). A palette change that misses the copy makes the
// splash -> app handoff flash. This keeps the copy honest.
const html = readFileSync(join(__dirname, "../index.html"), "utf8");
const css = readFileSync(join(__dirname, "main.css"), "utf8");

/** oklch(...) as its numbers, so `100%` and `100.00%` compare equal. */
function numbers(oklch: string): number[] {
	return [...oklch.matchAll(/-?\d+(?:\.\d+)?/gu)].map(([n]) => Number(n));
}

/** [light, dark] values of a main.css token. */
function token(name: string): [number[], number[]] {
	const found = [...css.matchAll(new RegExp(`--${name}:\\s*(oklch\\([^)]*\\))`, "gu"))].map(
		([, v]) => numbers(v ?? ""),
	);
	const [light, dark] = found;
	if (!(light && dark)) {
		throw new Error(`--${name} needs a light and a dark value in main.css`);
	}
	return [light, dark];
}

describe("index.html splash", () => {
	const splash = html.slice(html.indexOf("@layer splash"), html.indexOf("</style>"));
	// In source order: background, text, then the spinner's ring and arc.
	const [bgLight, bgDark, textLight, textDark, ringLight, arcLight, ringDark, arcDark] = [
		...splash.matchAll(/oklch\([^)]*\)/gu),
	].map(([v]) => numbers(v));

	it.each([
		["background", bgLight, bgDark],
		["muted-foreground", textLight, textDark],
		["border", ringLight, ringDark],
		["primary", arcLight, arcDark],
	])("matches main.css --%s in light and dark", (name, light, dark) => {
		expect([light, dark]).toEqual(token(name));
	});
});
