import { describe, expect, test } from "vitest";
import uiClasses from "./ui-classes?raw";

// Guard for docs/context/form-controls.md "Buttons": every standard button is
// the shared <Button>, with a role variant and layout-only classes.

const sources = import.meta.glob<string>(
	["/src/**/*.tsx", "!/src/components/ui/**", "!/src/**/*.test.tsx"],
	{
		query: "?raw",
		import: "default",
		eager: true,
	},
);

const ALLOWED_VARIANTS = new Set(["default", "outline", "destructive", "ghost", "link"]);

// A color, background, border, radius, height or ring utility. Layout (width,
// margin, gap, shrink-0, justify-*, positioning) is the only thing a className
// on a <Button> may carry.
const STYLE_UTILITY =
	/(?:^|:)(?:bg-|text-(?:red|green|amber|yellow|orange|blue|gray|slate|zinc|primary|destructive|muted|foreground|white|black|accent|secondary)|border-|rounded|h-\d|size-\d|ring-)/;

// Raw <button>s that stay raw because they are NOT standard buttons: tabs,
// rows, menu items, toggles, chips, selectable cards, overlays and surfaces
// that are forced light. Keyed by path; every entry must still hold a raw
// <button> (see the stale-entry test). Add a file here only with a reason.
const RAW_BUTTON_ALLOWLIST: Record<string, string> = {
	"/src/billing/billing-page.tsx":
		"dev-only checkout stub and the back link sit on the forced-light Paddle card; theme tokens would go light-on-light",
	"/src/layout/rail.tsx": "rail view/tool toggles (aria-current / aria-pressed icon tabs)",
	"/src/layout/right-tool-panel.tsx": "role=tab strip",
	"/src/layout/sidebar-view-toggle.tsx": "bottom view switcher (aria-current segmented nav)",
	"/src/layout/search-panel.tsx": "recent-query list rows and tag-chip remove inside a Badge",
	"/src/layout/vault-switcher.tsx": "listbox option rows (listRowClass)",
	"/src/onboarding/onboard-vault-page.tsx": "selectable source cards (aria-pressed)",
	"/src/billing/plan-cards.tsx": "accordion header row that opens a plan tier",
	"/src/viewer/tree-actions/action-drawer.tsx": "mobile sheet backdrop and menuitem rows",
	"/src/viewer/tree-actions/context-menu.tsx": "role=menuitem rows",
	"/src/viewer/tree/tree-row.tsx": "role=treeitem folder row",
	"/src/viewer/property-fields.tsx": "list-value chip remove",
	"/src/viewer/inline-title.tsx": "undecorated click-to-rename title text",
	"/src/viewer/note-page.tsx": "undecorated click-to-rename header name",
	"/src/settings/connections-page.tsx": "modal backdrop overlay",
};

// Walk from the "<" at `start` to the ">" that closes the opening tag,
// skipping over {...} expressions (arrow functions contain ">").
function openTag(src: string, start: number): string {
	let depth = 0;
	for (let i = start; i < src.length; i += 1) {
		const ch = src[i];
		if (ch === "{") {
			depth += 1;
		} else if (ch === "}") {
			depth -= 1;
		} else if (ch === ">" && depth === 0) {
			return src.slice(start, i + 1);
		}
	}
	return src.slice(start);
}

function tagsOf(src: string, re: RegExp): string[] {
	return [...src.matchAll(re)].map((m) => openTag(src, m.index));
}

function literals(text: string): string[] {
	return [...text.matchAll(/"[^"]*"|'[^']*'|`[^`]*`/g)].map((m) => m[0].slice(1, -1));
}

// The value of an attribute: a quoted string or a balanced {...} expression.
function attr(tag: string, name: string): string | null {
	const at = tag.search(new RegExp(`\\s${name}=`));
	if (at === -1) {
		return null;
	}
	const valueStart = at + name.length + 2;
	if (tag[valueStart] === '"') {
		return tag.slice(valueStart, tag.indexOf('"', valueStart + 1) + 1);
	}
	let depth = 0;
	for (let i = valueStart; i < tag.length; i += 1) {
		if (tag[i] === "{") {
			depth += 1;
		} else if (tag[i] === "}") {
			depth -= 1;
			if (depth === 0) {
				return tag.slice(valueStart, i + 1);
			}
		}
	}
	return tag.slice(valueStart);
}

const BUTTON_TAG = /<Button(?=[\s>/])/g;
const RAW_BUTTON_TAG = /<button(?=[\s>])/g;

describe("button style", () => {
	test("lib/ui-classes does not export button color constants", () => {
		expect(uiClasses).not.toMatch(/export const (?:ctaFilled|ctaOutline)\b/);
	});

	test("<Button> uses only the role variants", () => {
		const offenders: string[] = [];
		for (const [path, src] of Object.entries(sources)) {
			for (const tag of tagsOf(src, BUTTON_TAG)) {
				const variant = attr(tag, "variant");
				const bad = literals(variant ?? "").filter((v) => !ALLOWED_VARIANTS.has(v));
				if (bad.length > 0) {
					offenders.push(`${path}: variant ${bad.join(", ")}`);
				}
			}
		}
		expect(offenders).toEqual([]);
	});

	test("<Button> className is layout only", () => {
		const offenders: string[] = [];
		for (const [path, src] of Object.entries(sources)) {
			for (const tag of tagsOf(src, BUTTON_TAG)) {
				const classes = literals(attr(tag, "className") ?? "").flatMap((s) => s.split(/\s+/));
				const bad = classes.filter((c) => STYLE_UTILITY.test(c));
				if (bad.length > 0) {
					offenders.push(`${path}: ${bad.join(" ")}`);
				}
			}
		}
		expect(offenders).toEqual([]);
	});

	test("raw <button> does not hand-roll a button look", () => {
		const offenders: string[] = [];
		for (const [path, src] of Object.entries(sources)) {
			if (path in RAW_BUTTON_ALLOWLIST) {
				continue;
			}
			for (const tag of tagsOf(src, RAW_BUTTON_TAG)) {
				const cls = literals(attr(tag, "className") ?? "").join(" ");
				const solid = /\bbg-(?:primary|destructive)\b(?!\/)/.test(cls);
				const boxed = /\bborder\b/.test(cls) && /\brounded/.test(cls);
				if (solid || boxed) {
					offenders.push(`${path}: ${cls}`);
				}
			}
		}
		expect(offenders).toEqual([]);
	});

	test("every allow-list entry still has a raw <button>", () => {
		const stale = Object.keys(RAW_BUTTON_ALLOWLIST).filter((path) => {
			const src = sources[path];
			return src === undefined || tagsOf(src, RAW_BUTTON_TAG).length === 0;
		});
		expect(stale).toEqual([]);
	});
});
