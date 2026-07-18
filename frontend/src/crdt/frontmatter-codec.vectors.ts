// Shared frontmatter round-trip vectors. MUST stay identical in meaning to the
// plugin (plugin/src/crdt/frontmatter-codec.test.ts) and backend
// (Engram.Notes.Frontmatter tests). Edit in lockstep across all three surfaces.
export interface Vector {
	name: string;
	markdown: string; // full note text (fence + body, or body-only)
	order: string[]; // expected top-level key order
	// expected canonical-JSON value strings, keyed by frontmatter key
	values: Record<string, string>;
	body: string; // expected body after split
}

export const VECTORS: Vector[] = [
	{
		name: "no frontmatter",
		markdown: "just a body\n",
		order: [],
		values: {},
		body: "just a body\n",
	},
	{
		name: "empty frontmatter block",
		markdown: "---\n---\nbody\n",
		order: [],
		values: {},
		body: "body\n",
	},
	{
		name: "string, list, number, bool, date",
		markdown: '---\ntitle: Hi\ntags:\n  - a\n  - b\ncount: 3\ndone: true\ncreated: 2026-07-17\n---\nbody text\n',
		order: ["title", "tags", "count", "done", "created"],
		values: {
			title: JSON.stringify("Hi"),
			tags: JSON.stringify(["a", "b"]),
			count: JSON.stringify(3),
			done: JSON.stringify(true),
			// the `yaml` package parses an unquoted ISO date to a Date; canonicalJson
			// serializes it as an ISO string. Assert the shape the codec actually emits.
			created: JSON.stringify(new Date("2026-07-17").toISOString().slice(0, 10)),
		},
		body: "body text\n",
	},
	{
		name: "nested map",
		markdown: "---\nmeta:\n  a: 1\n  b: 2\n---\n",
		order: ["meta"],
		values: { meta: JSON.stringify({ a: 1, b: 2 }) },
		body: "",
	},
	{
		name: "unicode + colon in value",
		markdown: '---\nnote: "café: rebuilt"\n---\nx\n',
		order: ["note"],
		values: { note: JSON.stringify("café: rebuilt") },
		body: "x\n",
	},
];
