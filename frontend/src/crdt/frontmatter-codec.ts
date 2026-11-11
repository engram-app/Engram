// Mirrors the backend Elixir Engram.Notes.Frontmatter. Keep byte-compatible:
// a divergence corrupts notes across web/plugin/backend. Shared vectors in
// frontmatter-codec.vectors.ts pin the contract. splitFrontmatter is a TS copy
// of the Rust fence rule (native/engram_core/src/frontmatter.rs); the fixture
// table native/engram_core/fixtures/frontmatter_fence.json pins both. (The
// plugin's copy still opens only on LF: a follow-up there.)
import { parse as yamlParse, stringify as yamlStringify } from "yaml";

const FENCE = "---";
const CLOSE_MID = /\n---[ \t]*\r?\n/;
const CLOSE_EOF = /\n---[ \t]*\r?$/;

function sortDeep(v: unknown): unknown {
	if (Array.isArray(v)) {
		return v.map(sortDeep);
	}
	if (v !== null && typeof v === "object") {
		const rec: Record<string, unknown> = Object.fromEntries(Object.entries(v));
		const out: Record<string, unknown> = {};
		for (const k of Object.keys(rec).sort()) {
			out[k] = sortDeep(rec[k]);
		}
		return out;
	}
	return v;
}

function topLevelKeyOrder(block: string, map: Record<string, unknown>): string[] {
	const order: string[] = [];
	for (const line of block.split("\n")) {
		const m = line.match(/^(?<key>[^\s:][^:]*):/);
		if (!m) {
			continue;
		}
		const { key } = m.groups ?? {};
		if (key !== undefined && Object.hasOwn(map, key) && !order.includes(key)) {
			order.push(key);
		}
	}
	return order;
}

function ensureTrailingNewline(s: string): string {
	if (s === "") {
		return "";
	}
	return s.endsWith("\n") ? s : `${s}\n`;
}

function emitKey(key: string, valueJson: string): string {
	const value: unknown = JSON.parse(valueJson);
	return ensureTrailingNewline(yamlStringify({ [key]: value }));
}

// Length of an opening fence (`---` then LF or CRLF) at the start of `s`, else 0.
function openFence(s: string): number {
	if (s.startsWith(`${FENCE}\r\n`)) {
		return FENCE.length + 2;
	}
	return s.startsWith(`${FENCE}\n`) ? FENCE.length + 1 : 0;
}

export function splitFrontmatter(raw: string): { fmBlock: string | null; body: string } {
	const start = openFence(raw);
	if (start === 0) {
		return { fmBlock: null, body: raw };
	}
	const rest = raw.slice(start);
	const empty = openFence(rest);
	if (empty > 0) {
		return { fmBlock: "", body: rest.slice(empty) };
	}
	const mid = rest.match(CLOSE_MID);
	if (mid && mid.index !== undefined) {
		const block = `${rest.slice(0, mid.index)}\n`;
		const body = rest.slice(mid.index + mid[0].length);
		return { fmBlock: block, body };
	}
	const eof = rest.match(CLOSE_EOF);
	if (eof && eof.index !== undefined) {
		return { fmBlock: `${rest.slice(0, eof.index)}\n`, body: "" };
	}
	return { fmBlock: null, body: raw };
}

export function canonicalJson(value: unknown): string {
	return JSON.stringify(sortDeep(value));
}

export function parseFrontmatter(
	fmBlock: string,
): { order: string[]; values: Record<string, string> } | null {
	if (fmBlock === "") {
		return { order: [], values: {} };
	}
	let doc: unknown;
	try {
		doc = yamlParse(fmBlock);
	} catch {
		return null;
	}
	if (!doc || typeof doc !== "object" || Array.isArray(doc)) {
		return null;
	}
	const map: Record<string, unknown> = Object.fromEntries(Object.entries(doc));
	const order = topLevelKeyOrder(fmBlock, map);
	const values: Record<string, string> = {};
	for (const k of Object.keys(map)) {
		values[k] = canonicalJson(map[k]);
	}
	return { order, values };
}

export function emitFrontmatter(
	order: string[],
	values: Record<string, string>,
	raws: Record<string, string> = {},
): string {
	const has = (m: Record<string, string>, k: string) => Object.hasOwn(m, k);
	const present = order.filter((k) => has(raws, k) || has(values, k));
	if (present.length === 0) {
		return "";
	}
	let out = "";
	for (const key of present) {
		out += has(raws, key) ? ensureTrailingNewline(raws[key]!) : emitKey(key, values[key]!);
	}
	return ensureTrailingNewline(out);
}

export function projectNote(
	order: string[],
	values: Record<string, string>,
	body: string,
	raws: Record<string, string> = {},
): string {
	const block = emitFrontmatter(order, values, raws);
	return block === "" ? body : `${FENCE}\n${block}${FENCE}\n${body}`;
}
