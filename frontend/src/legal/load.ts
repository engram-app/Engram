import manifest from "./versions/legal-manifest.json";

const mds = import.meta.glob("./versions/*.md", {
	query: "?raw",
	import: "default",
	eager: true,
}) as Record<string, string>;

export async function sha256Hex(text: string): Promise<string> {
	const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
	return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function loadVersion(doc: "terms" | "privacy", version: string): string {
	const text = mds[`./versions/${doc}-${version}.md`];
	if (text === undefined) {
		throw new Error(`legal: missing bundled ${doc}-${version}.md — run "bun run sync-theme"`);
	}
	return text;
}

export { manifest };
