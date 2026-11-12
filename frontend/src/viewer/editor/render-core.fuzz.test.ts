import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState, type StateField } from "@codemirror/state";
import type { DecorationSet } from "@codemirror/view";
import { TreeFragment } from "@lezer/common";
import { parser } from "@lezer/markdown";
import { describe, expect, test } from "vitest";
import { attachmentEmbeds } from "./attachment-embed";
import { blockquoteDepthPlugin } from "./blockquote-depth";
import { calloutDecoration } from "./callout-decoration";
import { commentDecoration } from "./comment-decoration";
import { indentedCodeLines } from "./indented-code";
import { katexDecoration } from "./katex-decoration";
import { listRails } from "./list-rails";
import { mermaidDecoration } from "./mermaid-decoration";
import { type Placed, placed, settle } from "./render-test-utils";

// Randomised check of the render core: every renderer, after every edit, must
// equal a fresh build of the same document. The edit shapes are the ones that
// change structure far from the edit: fence and `%%`/`$$` delimiters typed or
// broken, HTML blocks made and unmade, list markers, indentation, joins.

const embeds = attachmentEmbeds({ resolve: (t) => `img/${t}`, load: () => Promise.resolve("x") });
const fields: [string, StateField<DecorationSet>][] = [
	["comments", commentDecoration],
	["indented code", indentedCodeLines],
	["list rails", listRails[0] as StateField<DecorationSet>],
	["mermaid", mermaidDecoration],
	["embeds", embeds[0] as StateField<DecorationSet>],
	["math", katexDecoration],
	["callouts", calloutDecoration],
	["blockquote", blockquoteDepthPlugin],
];
const ext = [
	markdown({ base: markdownLanguage }),
	commentDecoration,
	indentedCodeLines,
	listRails,
	mermaidDecoration,
	embeds,
	katexDecoration,
	calloutDecoration,
	blockquoteDepthPlugin,
];

const FRAGMENTS = [
	"para text\n",
	"```js\ncode %% x\n```\n",
	"````md\n```js\n````\n",
	"```mermaid\ngraph LR\n  A --> B\n```\n",
	"%%\nblock\ncomment\n%%\n",
	"a %%inline%% b\n",
	"<div>\nhtml\n```re\n</div>\n",
	"$$ lone\nmore\n",
	"$$\nx^2\n$$\n",
	"price $5 and $x^2$ here\n",
	"\tcode1\n\tcode2\n",
	"- a\n\t- b\n\t\t- c\n",
	"1. one\n2. two\n",
	"> [!tip] Title\n> body\n",
	"> quote\n>> deeper\n",
	"see ![[pic.png]] now\n",
	"\n",
	"text\n\n    code\n    more\n",
	"1. x\n   > q\n  > 1.  - y\n",
];
const INSERTS = [
	"```",
	"````",
	"~~~",
	"%%",
	"$$",
	"$",
	"<div>",
	"</div>",
	"- ",
	"\t",
	"> ",
	"\n",
	"\n\n",
	"x",
	"`",
	"![[p.png]]",
	"> [!note]",
];

/** A seeded LCG: the same seed always replays the same failing case. */
function rng(seed: number) {
	let x = seed;
	return (n: number) => {
		x = (x * 1_103_515_245 + 12_345) % 2_147_483_648;
		return Math.floor((x / 2_147_483_648) * n);
	};
}

const pick = <T>(r: (n: number) => number, xs: T[]): T => xs[r(xs.length)] as T;

function sig(p: Placed[]) {
	return p.map(
		([f, t, d]) =>
			`${f}-${t}:${JSON.stringify(d.spec.attributes ?? d.spec.class ?? d.spec.widget?.constructor.name ?? "")}`,
	);
}

describe("render core fuzz", () => {
	test("incremental equals a fresh build after structural edits (160 docs x 6 edits)", () => {
		const failures: string[] = [];
		for (let seed = 1; seed <= 160 && failures.length < 3; seed++) {
			const r = rng(seed);
			const doc = Array.from({ length: 4 + r(10) }, () => pick(r, FRAGMENTS)).join("");
			let s = settle(EditorState.create({ doc, extensions: ext }));
			for (let step = 0; step < 6; step++) {
				const len = s.doc.length;
				const at = r(len + 1);
				const kind = r(4);
				const lineEdge = s.doc.lineAt(at);
				const changes =
					kind === 3
						? // Enter at a line edge, e.g. on the blank line above a block.
							{ from: r(2) ? lineEdge.from : lineEdge.to, insert: "\n" }
						: kind === 0
							? { from: at, insert: pick(r, INSERTS) }
							: kind === 1
								? { from: at, to: Math.min(len, at + 1 + r(6)) }
								: { from: at, to: Math.min(len, at + r(4)), insert: pick(r, INSERTS) };
				s = s.update({ changes }).state;
				s = s.update({ selection: { anchor: r(s.doc.length + 1) } }).state;
				// Sometimes compare before the parser finishes, as a lagging view would.
				if (r(3) > 0) {
					s = settle(s);
				}
				const want = settle(
					EditorState.create({ doc: s.doc, selection: s.selection, extensions: ext }),
				);
				const settled = settle(s);
				for (const [name, f] of fields) {
					const got = sig(placed(settled.field(f)));
					const exp = sig(placed(want.field(f)));
					if (JSON.stringify(got) !== JSON.stringify(exp)) {
						failures.push(`seed ${seed} step ${step} ${name}: ${JSON.stringify(s.doc.toString())}`);
						break;
					}
				}
				s = settled;
			}
		}
		expect(failures).toEqual([]);
	}, 120_000);

	// Known upstream (not render-core) divergences. Fresh seeds outside 1-160 that
	// fail ONLY through one of these are not our bug; anything else is.
	//
	// Seed 7207, "indented code" layer: @lezer/markdown (1.7.2, still in 1.8.1)
	// reuses a stale CodeBlock on an incremental reparse after the first line's
	// indent is deleted, so the incremental tree differs from a fresh parse. Later
	// edits re-parse that region without a change there, so the core never
	// re-renders it. This canary fails once upstream fixes it: then add 7207 to
	// the fuzz run as a regression.
	test("known upstream: lezer keeps a stale CodeBlock after an indent is deleted", () => {
		const pre = "\tcode1\n\tcode2\npara\n";
		const post = pre.slice(1);
		const reused = TreeFragment.applyChanges(TreeFragment.addTree(parser.parse(pre)), [
			{ fromA: 0, toA: 1, fromB: 0, toB: 0 },
		]);
		expect(parser.parse(post).toString()).toBe("Document(Paragraph)");
		expect(parser.parse(post, reused).toString()).toBe(
			"Document(CodeBlock(CodeText,CodeText),Paragraph)",
		);
	});
});
