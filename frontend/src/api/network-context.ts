// What a network_error report carries besides its route. The browser hides the
// real cause of a failed fetch ("Failed to fetch" is all it says), so these
// are the signals that can still tell causes apart: a fast refusal vs a stall
// (elapsed_ms), a link that dropped mid-request, a backgrounded tab, a slow
// link, one browser build.
// Every field is an enum, a number or a family+major: nothing identifying, and
// the backend allowlists the same set (Engram.Logs) before it reaches Loki.

interface NetworkContext {
	browser: string;
	went_offline: boolean;
	attempt: number;
	elapsed_ms: number;
	error_name: string;
	error_message: string;
	visibility: DocumentVisibilityState;
	effective_type?: string;
}

// The texts browsers use for a failed fetch (Chrome, Safari, Firefox). Fixed
// strings, so they can be forwarded; anything else might carry a URL.
const FETCH_FAILURE_MESSAGES = new Set([
	"Failed to fetch",
	"Load failed",
	"NetworkError when attempting to fetch resource.",
]);
const ERROR_NAMES = new Set(["TypeError", "AbortError", "TimeoutError", "NetworkError"]);
const EFFECTIVE_TYPES = new Set(["slow-2g", "2g", "3g", "4g"]);

// Client Hints brands, most specific first; "Chromium" is every Chromium fork.
const BRANDS: [brand: string, family: string][] = [
	["Microsoft Edge", "Edge"],
	["Opera", "Opera"],
	["Brave", "Brave"],
	["Google Chrome", "Chrome"],
	["Chromium", "Chromium"],
];

// UA fallback (Firefox and Safari have no userAgentData). Order matters: Edge
// and Opera also say Chrome, and Chrome also says Safari.
const UA_PATTERNS: [pattern: RegExp, family: string][] = [
	[/\bEdg\/(?<major>\d+)/u, "Edge"],
	[/\bOPR\/(?<major>\d+)/u, "Opera"],
	[/\bFirefox\/(?<major>\d+)/u, "Firefox"],
	[/\bChrome\/(?<major>\d+)/u, "Chrome"],
	[/\bVersion\/(?<major>\d+)[\d.]* (?:Mobile\/\S+ )?Safari\//u, "Safari"],
];

// Count of `offline` events, so a request can tell whether the link dropped
// while it was in flight. navigator.onLine itself is useless here: a report
// is only sent while it is true (client.ts), so it would always read true.
let offlineEvents = 0;
if (typeof window !== "undefined") {
	window.addEventListener("offline", () => {
		offlineEvents += 1;
	});
}

/** A mark to pass back to networkContext: "offline since this point?" */
function offlineMark(): number {
	return offlineEvents;
}

interface Brand {
	brand: string;
	version: string;
}

interface NavigatorExtras {
	userAgentData?: { brands?: Brand[] };
	connection?: { effectiveType?: string };
}

function extras(): NavigatorExtras {
	const nav: Navigator & NavigatorExtras = navigator;
	return { userAgentData: nav.userAgentData, connection: nav.connection };
}

/** Browser family and major version, e.g. "Chrome 155". Never the full UA. */
function browserFamily(): string {
	const brands = extras().userAgentData?.brands ?? [];
	for (const [brand, family] of BRANDS) {
		const hit = brands.find((b) => b.brand === brand);
		const major = hit?.version.match(/^\d+/u)?.[0];
		if (major) {
			return `${family} ${major}`;
		}
	}
	for (const [pattern, family] of UA_PATTERNS) {
		const major = navigator.userAgent.match(pattern)?.groups?.major;
		if (major) {
			return `${family} ${major}`;
		}
	}
	return "unknown";
}

function networkContext(
	err: Error,
	attempt: number,
	elapsedMs: number,
	sinceOfflineMark: number,
): NetworkContext {
	const effectiveType = extras().connection?.effectiveType;
	return {
		browser: browserFamily(),
		went_offline: offlineEvents !== sinceOfflineMark,
		attempt,
		elapsed_ms: Math.round(elapsedMs),
		error_name: ERROR_NAMES.has(err.name) ? err.name : "other",
		error_message: FETCH_FAILURE_MESSAGES.has(err.message) ? err.message : "other",
		visibility: document.visibilityState,
		...(effectiveType && EFFECTIVE_TYPES.has(effectiveType)
			? { effective_type: effectiveType }
			: {}),
	};
}

export type { NetworkContext };
export { networkContext, offlineMark };
