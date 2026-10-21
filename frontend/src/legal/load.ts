import { whenLoaded } from "@/lib/when-loaded";

// Lazy: each historical policy is its own chunk, fetched only when shown.
const mds = import.meta.glob<{ default: string }>("./versions/*.md", { query: "?raw" });

export type LegalDocKind = "terms" | "privacy";

export async function sha256Hex(text: string): Promise<string> {
	const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
	return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// The newest version of `doc` this bundle ships that is not newer than
// `wanted`. Versions are YYYY-MM-DD, so string order is date order.
export function renderableVersion(doc: LegalDocKind, wanted: string): string | undefined {
	const prefix = `./versions/${doc}-`;
	return Object.keys(mds)
		.filter((path) => path.startsWith(prefix))
		.map((path) => path.slice(prefix.length, -".md".length))
		.filter((version) => version <= wanted)
		.sort()
		.at(-1);
}

export function loadVersion(doc: LegalDocKind, version: string): Promise<string> {
	const load = mds[`./versions/${doc}-${version}.md`];
	if (!load) {
		return Promise.reject(
			new Error(`legal: missing bundled ${doc}-${version}.md — run "bun run sync-theme"`),
		);
	}
	// Not `import: "default"`: Vite would read `.default` of an undefined module; see whenLoaded.
	return whenLoaded(load()).then((m) => m.default);
}
