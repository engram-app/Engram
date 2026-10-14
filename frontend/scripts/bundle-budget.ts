// What the browser must fetch and run before the app can start: the entry
// module plus every chunk index.html modulepreloads. Lazy chunks and CSS are
// not counted. Used by check-bundle-budget.ts.

const ENTRY = /<script type="module"[^>]*\ssrc="\/assets\/(?<file>[^"]+\.js)"/u;
const PRELOAD = /<link rel="modulepreload"[^>]*\shref="\/assets\/(?<file>[^"]+\.js)"/gu;

export function initialScripts(html: string): string[] {
	const entry = ENTRY.exec(html)?.groups?.file;
	if (!entry) {
		throw new Error("index.html has no entry module script");
	}
	const preloads = [...html.matchAll(PRELOAD)].flatMap((m) => m.groups?.file ?? []);
	return [entry, ...preloads];
}
