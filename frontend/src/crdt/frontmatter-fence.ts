// The frontmatter fence split as the backend runs it: the Rust rule in
// native/engram_core/src/frontmatter.rs, compiled to wasm32 by
// native/web_wasm (frontmatter-fence.wasm is committed; CI rebuilds it and
// fails on a byte diff). Optional by design: until loadFenceWasm() resolves,
// or if it rejects (no WebAssembly, a CSP without 'wasm-unsafe-eval', a
// failed self-check), splitFrontmatter keeps its TS path, which the same
// fixture table (native/engram_core/fixtures/frontmatter_fence.json) pins.

interface FenceSplit {
	fmBlock: string | null;
	body: string;
}

interface Exports {
	memory: WebAssembly.Memory;
	input_ptr(): number;
	out_ptr(): number;
	fm_split(len: number): number;
}

const PAGE = 65_536;
// A lone surrogate would reach the wasm as U+FFFD, so the TS path takes it.
const LONE_SURROGATE = /\p{Cs}/u;

let wasmSplit: ((raw: string) => FenceSplit) | undefined;

function isFenceExports(e: WebAssembly.Exports): e is WebAssembly.Exports & Exports {
	return (
		e.memory instanceof WebAssembly.Memory &&
		typeof e.input_ptr === "function" &&
		typeof e.out_ptr === "function" &&
		typeof e.fm_split === "function"
	);
}

async function bundled(): Promise<WebAssembly.Instance> {
	const { default: init } = await import("./frontmatter-fence.wasm?init");
	return init();
}

/** The wasm split, or undefined when it is not loaded or `raw` holds a lone
 *  surrogate (the caller then uses the TS path). */
export function fenceSplit(raw: string): FenceSplit | undefined {
	return wasmSplit && !LONE_SURROGATE.test(raw) ? wasmSplit(raw) : undefined;
}

/** Test seam: back to the TS path. */
export function resetFenceWasm(): void {
	wasmSplit = undefined;
}

/** Instantiates the module (async: Chromium refuses sync compiles on the
 *  main thread past 4 KB) and switches splitFrontmatter over once it passes
 *  a known-answer check. Rejects, leaving the TS path, otherwise. */
export async function loadFenceWasm(
	instantiate: () => Promise<{ exports: WebAssembly.Exports }> = bundled,
): Promise<void> {
	const ex = (await instantiate()).exports;
	if (!isFenceExports(ex)) {
		throw new Error("frontmatter fence wasm lacks its exports");
	}
	const encoder = new TextEncoder();
	const decoder = new TextDecoder();

	const candidate = (raw: string): FenceSplit => {
		const base = ex.input_ptr();
		// UTF-8 is at most 3 bytes per UTF-16 unit.
		// ponytail: memory only grows; the largest note opened sets the size.
		const need = base + raw.length * 3 - ex.memory.buffer.byteLength;
		if (need > 0) {
			ex.memory.grow(Math.ceil(need / PAGE));
		}
		const mem = new Uint8Array(ex.memory.buffer);
		const { written } = encoder.encodeInto(raw, mem.subarray(base));
		if (ex.fm_split(written) === 0) {
			return { fmBlock: null, body: raw };
		}
		const [bs = 0, be = 0, body = 0, nl = 0] = new Uint32Array(ex.memory.buffer, ex.out_ptr(), 4);
		const bytes = mem.subarray(base, base + written);
		return {
			fmBlock: decoder.decode(bytes.subarray(bs, be)) + (nl ? "\n" : ""),
			body: decoder.decode(bytes.subarray(body)),
		};
	};

	const crlf = candidate("---\r\né: 1\r\n---\r\n€");
	const none = candidate("---\nx");
	if (crlf.fmBlock !== "é: 1\r\n" || crlf.body !== "€" || none.fmBlock !== null) {
		throw new Error("frontmatter fence wasm failed its self-check");
	}
	wasmSplit = candidate;
}
