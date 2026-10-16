import { parseSync } from "vite";
import { describe, expect, it } from "vitest";

// Biome's noJsxLiterals sees only bare JSX text, and keys.test.ts only `attr="..."`.
// English written as an expression slips past both: `{n > 1 ? "Words" : "Word"}`,
// `title={c ? "A" : "B"}`, an aria-label built from a template. This walks the real
// syntax tree and flags a literal with two or more letters wherever it would be
// rendered as-is: a JSX child expression, or a user-facing attribute's expression.
// className and the other non-UI attributes are not scanned.

// Attributes whose value a person reads or hears.
const UI_ATTRS = new Set([
	"placeholder",
	"aria-label",
	"aria-description",
	"aria-valuetext",
	"aria-roledescription",
	"title",
	"alt",
	"label",
]);

// Text that is the same in every language, each with its reason.
const ALLOWED = new Map<string, string>([]);

const LETTERS = /\p{L}{2}/u;

interface Node {
	type: string;
	[key: string]: unknown;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null;
}

function isNode(value: unknown): value is Node {
	return (
		typeof value === "object" && value !== null && typeof Reflect.get(value, "type") === "string"
	);
}

// The literals an expression can evaluate to, followed through ternaries and
// `&&` / `||` / `??`, but not into calls (a translated call is the fix) or JSX.
function shown(e: unknown): string[] {
	if (!isNode(e)) {
		return [];
	}
	switch (e.type) {
		case "Literal":
			return typeof e.value === "string" && LETTERS.test(e.value) ? [e.value] : [];
		case "TemplateLiteral": {
			const quasis = Array.isArray(e.quasis) ? e.quasis : [];
			const text = quasis
				.map((q: unknown) => (isNode(q) && isRecord(q.value) ? String(q.value.raw) : ""))
				.join("{}");
			return LETTERS.test(text) ? [text] : [];
		}
		case "ConditionalExpression":
			return [...shown(e.consequent), ...shown(e.alternate)];
		case "LogicalExpression":
			return e.operator === "&&" ? shown(e.right) : [...shown(e.left), ...shown(e.right)];
		case "ParenthesizedExpression":
		case "TSAsExpression":
		case "TSSatisfiesExpression":
		case "TSNonNullExpression":
			return shown(e.expression);
		default:
			return [];
	}
}

function attrName(attr: Node): string {
	const { name } = attr;
	return isNode(name) && typeof name.name === "string" ? name.name : "";
}

function jsxLeaks(source: string, filename = "x.tsx"): string[] {
	const found: string[] = [];
	const visit = (node: unknown): void => {
		if (Array.isArray(node)) {
			node.forEach(visit);
			return;
		}
		if (!isNode(node)) {
			return;
		}
		if (node.type === "JSXAttribute" && UI_ATTRS.has(attrName(node)) && isNode(node.value)) {
			found.push(...shown(node.value.expression));
		}
		if (node.type === "JSXElement" || node.type === "JSXFragment") {
			for (const child of Array.isArray(node.children) ? node.children : []) {
				if (isNode(child) && child.type === "JSXExpressionContainer") {
					found.push(...shown(child.expression));
				}
			}
		}
		for (const [key, value] of Object.entries(node)) {
			if (key !== "type" && typeof value === "object") {
				visit(value);
			}
		}
	};
	const { program, errors } = parseSync(filename, source, { lang: "tsx" });
	if (errors.length > 0) {
		throw new Error(`${filename}: ${errors[0]?.message}`);
	}
	visit(program);
	return found.filter((text) => !ALLOWED.has(text));
}

// Writes a template placeholder into test source without a lint-tripping literal.
const D = "$";

describe("jsxLeaks (self-check)", () => {
	it("flags literals in child expressions and ternaries", () => {
		expect(jsxLeaks(`<p>{n > 1 ? "Plural words" : "Single word"}</p>`)).toEqual([
			"Plural words",
			"Single word",
		]);
		expect(jsxLeaks(`<p>{"Hello there"}</p>`)).toEqual(["Hello there"]);
		expect(jsxLeaks(`<p>{busy && "Saving"}</p>`)).toEqual(["Saving"]);
		expect(jsxLeaks(`<p>{name ?? "Unknown"}</p>`)).toEqual(["Unknown"]);
		expect(jsxLeaks(`<p>{\`Hello ${D}{name}\`}</p>`)).toEqual(["Hello {}"]);
	});
	it("flags user-facing attributes, including templates", () => {
		expect(jsxLeaks(`<b title={c ? "A b" : "Cd"} />`)).toEqual(["Cd"]);
		expect(jsxLeaks(`<b aria-label={\`Open ${D}{name}\`} />`)).toEqual(["Open {}"]);
		expect(jsxLeaks(`<b placeholder={"Search"} />`)).toEqual(["Search"]);
	});
	it("ignores translated calls, non-UI attributes, symbols and conditions", () => {
		expect(
			jsxLeaks(
				`<b className={c ? "flex gap" : "hidden"} variant={c ? "default" : "outline"}
					title={t("Open {name}", { name })}>
					{t(c ? x : y)}{x === "draft" ? t("Draft") : null}{" · "}{count}{\`\${a}/\${b}\`}
				</b>`,
			),
		).toEqual([]);
	});
});

describe("repo source", () => {
	// Shipped UI only: src/dev is DEV-only, the same carve-out as noJsxLiterals.
	const files = import.meta.glob<string>(["../**/*.tsx", "!../**/*.test.*", "!../dev/**"], {
		query: "?raw",
		import: "default",
		eager: true,
	});
	it("has no raw English in JSX expressions", () => {
		// A glob that matches nothing would pass vacuously.
		expect(Object.keys(files).length).toBeGreaterThan(100);
		const leaks = Object.entries(files).flatMap(([path, source]) =>
			jsxLeaks(source, path).map((text) => `${path.slice(3)}: ${text}`),
		);
		expect(leaks).toEqual([]);
		// Parses every shipped .tsx: ~2 s alone, past the 5 s default under a loaded
		// full run (seen 6.1 s on 2026-10-16). The cost grows with the repo, not a hang.
	}, 30_000);
});
