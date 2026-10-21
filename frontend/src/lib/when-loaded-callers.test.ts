import { describe, expect, it } from "vitest";

// Every dynamic import() whose module is read must go through whenLoaded (see
// when-loaded.ts): vite:preloadError's preventDefault() makes a failed import
// RESOLVE undefined, and reading it throws before the reload lands (Sentry
// ENGRAM-FRONTEND-3/-6/-B). A plain `import()` added next month reopens that,
// and nothing else would notice.
//
// import.meta.glob loaders (locale-provider.tsx, legal/load.ts) are dynamic
// imports this scan cannot see; both handle an undefined module themselves.

/** Unwrapped calls that are fine, each with the reason. */
const ALLOWED: { file: string; call: RegExp; why: string }[] = [
	{
		file: "i18n/vendor-locales.ts",
		call: /localizationLoader\(\(\) => import\(/,
		why: "localizationLoader reads the module with ?. and tolerates undefined",
	},
	{
		file: "viewer/note-chunks.ts",
		call: /preloadable\(\(\) => import\(/,
		why: "preloadable wraps the loader in whenLoaded itself",
	},
	{
		file: "billing/upgrade-dialog-provider.tsx",
		call: /^\s*import\("\.\/upgrade-required-dialog"\)\.catch\(/,
		why: "chunk warm-up: the module is never read",
	},
];

/** `file:line` of every runtime import() not routed through whenLoaded. */
function unwrappedImports(file: string, source: string): string[] {
	const lines = source.split("\n");
	return lines.flatMap((line, i) => {
		const text = line.trim();
		if (text.startsWith("*") || text.startsWith("//") || text.startsWith("/*")) {
			return [];
		}
		const bad = [...line.matchAll(/(?<![\w$.])import\(/g)].filter((m) => {
			const before = line.slice(0, m.index);
			return !(/whenLoaded\(\s*$/.test(before) || /typeof\s+$/.test(before));
		});
		const allowed = ALLOWED.some((a) => a.file === file && a.call.test(line));
		return bad.length > 0 && !allowed ? [`${file}:${i + 1}`] : [];
	});
}

const sources = import.meta.glob<string>(["../**/*.{ts,tsx}", "!../**/*.test.*"], {
	query: "?raw",
	import: "default",
	eager: true,
});

describe("unwrappedImports (self-check)", () => {
	it("flags a plain import() whose module is read", () => {
		const src = `const Page = lazy(() => import("./page"));`;
		expect(unwrappedImports("x.tsx", src)).toEqual(["x.tsx:1"]);
	});
	it("flags a .then on a plain import()", () => {
		expect(unwrappedImports("x.ts", `import("mermaid").then((m) => m.default);`)).toEqual([
			"x.ts:1",
		]);
	});
	it("passes whenLoaded, type-only imports and comments", () => {
		const src = [
			`const Page = lazy(() => whenLoaded(import("./page")));`,
			`type Sdk = typeof import("@sentry/react");`,
			" * calling `import()` next to a React.lazy",
			`// import("./old")`,
		].join("\n");
		expect(unwrappedImports("x.tsx", src)).toEqual([]);
	});
	it("allows a listed call only in its own file", () => {
		const src = `const v = preloadable(() => import("./note-view"));`;
		expect(unwrappedImports("viewer/note-chunks.ts", src)).toEqual([]);
		expect(unwrappedImports("viewer/other.ts", src)).toEqual(["viewer/other.ts:1"]);
	});
});

describe("source dynamic imports", () => {
	it("scans the source tree", () => {
		expect(Object.keys(sources).length).toBeGreaterThan(100);
	});
	it("routes every read import() through whenLoaded", () => {
		const offenders = Object.entries(sources).flatMap(([path, source]) =>
			unwrappedImports(path.replace(/^\.\.\//, ""), source),
		);
		expect(offenders).toEqual([]);
	});
	// A stale allowance would silently pass a new unwrapped call that happens
	// to match it.
	it("allows only calls that still exist", () => {
		const stale = ALLOWED.filter(
			(a) => !(sources[`../${a.file}`] ?? "").split("\n").some((line) => a.call.test(line)),
		);
		expect(stale).toEqual([]);
	});
});
