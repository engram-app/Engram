// PORTED VERBATIM from plugin/src/crdt/frontmatter-codec.ts (which mirrors the
// backend Elixir Engram.Notes.Frontmatter). Keep byte-compatible with both — a
// divergence corrupts notes across web/plugin/backend. Shared vectors in
// frontmatter-codec.vectors.ts pin the contract. Do not "improve" in isolation.
import { parse as yamlParse, stringify as yamlStringify } from "yaml";

const FENCE = "---";
const CLOSE_MID = /\n---[ \t]*\r?\n/;
const CLOSE_EOF = /\n---[ \t]*\r?$/;

export function splitFrontmatter(raw: string): { fmBlock: string | null; body: string } {
	if (!raw.startsWith(`${FENCE}\n`)) return { fmBlock: null, body: raw };
	const rest = raw.slice(FENCE.length + 1);
	if (rest.startsWith(`${FENCE}\n`)) return { fmBlock: "", body: rest.slice(FENCE.length + 1) };
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

function sortDeep(v: unknown): unknown {
	if (Array.isArray(v)) return v.map(sortDeep);
	if (v !== null && typeof v === "object") {
		const rec = v as Record<string, unknown>;
		const out: Record<string, unknown> = {};
		for (const k of Object.keys(rec).sort()) out[k] = sortDeep(rec[k]);
		return out;
	}
	return v;
}

export function parseFrontmatter(
	fmBlock: string,
): { order: string[]; values: Record<string, string> } | null {
	if (fmBlock === "") return { order: [], values: {} };
	let doc: unknown;
	try {
		doc = yamlParse(fmBlock);
	} catch {
		return null;
	}
	if (!doc || typeof doc !== "object" || Array.isArray(doc)) return null;
	const map = doc as Record<string, unknown>;
	const order = topLevelKeyOrder(fmBlock, map);
	const values: Record<string, string> = {};
	for (const k of Object.keys(map)) values[k] = canonicalJson(map[k]);
	return { order, values };
}

function topLevelKeyOrder(block: string, map: Record<string, unknown>): string[] {
	const order: string[] = [];
	for (const line of block.split("\n")) {
		const m = line.match(/^([^\s:][^:]*):/);
		if (!m) continue;
		const key = m[1];
		if (
			key !== undefined &&
			Object.prototype.hasOwnProperty.call(map, key) &&
			!order.includes(key)
		) {
			order.push(key);
		}
	}
	return order;
}

function ensureTrailingNewline(s: string): string {
	if (s === "") return "";
	return s.endsWith("\n") ? s : `${s}\n`;
}

function emitKey(key: string, valueJson: string): string {
	const value: unknown = JSON.parse(valueJson);
	return ensureTrailingNewline(yamlStringify({ [key]: value }));
}

export function emitFrontmatter(
	order: string[],
	values: Record<string, string>,
	raws: Record<string, string> = {},
): string {
	const has = (m: Record<string, string>, k: string) =>
		Object.prototype.hasOwnProperty.call(m, k);
	const present = order.filter((k) => has(raws, k) || has(values, k));
	if (present.length === 0) return "";
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
