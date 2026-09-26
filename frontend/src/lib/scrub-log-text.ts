// Egress scrub for free text leaving the SPA (Sentry exception values).
//
// A verbatim port of the Obsidian plugin's `scrubLogText` (engram-obsidian-sync
// src/error-util.ts) and behaviorally identical to the server's
// Engram.Logs.TextScrubber, so all three redact the same shapes. Keep them in
// sync: tests/scrub-log-text.test.ts mirrors the plugin's cases.

/**
 * Rule A — a quoted run that is a path. Kept identical to the server's
 * `Engram.Logs.TextScrubber` and the SPA Sentry scrub.
 *
 * A quote only OPENS at a boundary (start, whitespace, or `( [ { = : ,`) and
 * only CLOSES at one (end, whitespace, or `) ] } , . ; : |`), so the apostrophe
 * in `can't`/`won't` never pairs up and eats the `| key=value` fields between.
 * One alternative per delimiter so `"Medical/Tom's notes.md"` still matches.
 * The content class excludes its own quote and newline, so a failed close
 * backtracks at most one span — linear. Slash presence, the 512-per-side bound
 * and the API-route exemption are checked in `redactQuoted`, not in the regex.
 */
const EGRESS_QUOTED =
	/(?<pre>^|[\s([{=:,])(?:'(?<single>[^'\n]{1,1025})'|"(?<double>[^"\n]{1,1025})"|`(?<tick>[^`\n]{1,1025})`)(?=$|[\s)\]},.;:|])/g;

/** An API route is signal, not a vault path. Lowercase only. */
const API_ROUTE = /^\/api(?:\/[a-z0-9_:.-]*)*$/;

function redactQuoted(
	match: string,
	pre: string,
	single?: string,
	double?: string,
	tick?: string,
): string {
	const content = single ?? double ?? tick ?? "";
	const quote = single === undefined ? (double === undefined ? "`" : '"') : "'";
	if (API_ROUTE.test(content)) {
		return match;
	}
	// Some separator with at most 512 chars on each side of it.
	for (let i = 0; i < content.length; i++) {
		const c = content[i];
		if ((c === "/" || c === "\\") && i <= 512 && content.length - i - 1 <= 512) {
			return `${pre}${quote}<path>${quote}`;
		}
	}
	return match;
}

/**
 * Rule C — a home-directory or Windows-drive path, unquoted. Either one names
 * the OS user or sits outside anything a route could look like, so it is
 * redacted up to the next `|` field separator or end of line — the remainder
 * may contain spaces (`/Users/alice/My Vault/…`). One greedy negated class after
 * a literal anchor: linear. `\b` keeps `https://` from reading as `s:/`.
 */
const HOME_OR_DRIVE_PATH = /(?:~|\/Users|\/home|\b[A-Za-z]:(?=[\\/]))[\\/][^\n|]*/gi;

/** Note/attachment extensions a vault file token can end in. */
const VAULT_EXT =
	/\.(?:md|markdown|canvas|base|excalidraw|txt|rtf|csv|tsv|json|html?|xml|pdf|epub|docx?|xlsx?|pptx?|odt|ods|odp|key|pages|numbers|png|jpe?g|gif|bmp|svg|webp|avif|heic|heif|tiff?|mp3|wav|ogg|m4a|flac|aac|mp4|mov|webm|mkv|avi|zip)$/i;

const TRAILING_PUNCT = new Set([",", ".", ";", ":", ")", "]", "}", '"', "'"]);
/** How far back a spaced title may reach for its folder token. */
const MAX_BACKWALK = 8;

function stripTrailingPunct(token: string): string {
	// A loop, not `/[…]+$/`: that regex is quadratic on a long punctuation run.
	let end = token.length;
	while (end > 0 && TRAILING_PUNCT.has(token[end - 1] ?? "")) {
		end--;
	}
	return token.slice(0, end);
}

const hasSep = (t: string) => t.includes("/") || t.includes("\\");
const isField = (t: string) => t.includes("|") || t.includes("=");

/**
 * Rule B — an unquoted vault path whose title contains spaces. For each token
 * ending in a vault extension, walk back ≤8 tokens to the nearest token with a
 * separator (the folder part), extend over directly-preceding separator tokens,
 * never crossing a `|`/`=` field token, and redact the whole span. No slash in
 * the window → only the extension token goes. Plain token scans with a bounded
 * back-walk, and each token lands in at most one span: linear.
 */
function redactSpacedPaths(line: string): string {
	if (!line.includes(".")) {
		return line;
	}
	const toks = line.split(" ");
	// Loops, not `out.push(...slice)`: spreading a 100k-token slice is slow and
	// throws RangeError past the engine's argument limit.
	const out: string[] = [];
	const emit = (from: number, to: number) => {
		for (let k = from; k < to; k++) {
			out.push(toks[k] ?? "");
		}
	};
	let floor = 0; // first token not yet emitted
	for (let i = 0; i < toks.length; i++) {
		const tok = toks[i] ?? "";
		if (!(tok.includes(".") && VAULT_EXT.test(stripTrailingPunct(tok)))) {
			continue;
		}
		let start = i;
		for (let j = i; j >= Math.max(floor, i - MAX_BACKWALK); j--) {
			const back = toks[j] ?? "";
			if (j < i && isField(back)) {
				break;
			}
			if (hasSep(back)) {
				start = j;
				while (start > floor && hasSep(toks[start - 1] ?? "") && !isField(toks[start - 1] ?? "")) {
					start--;
				}
				break;
			}
		}
		emit(floor, start);
		out.push("<path>");
		floor = i + 1;
	}
	emit(floor, toks.length);
	return out.join(" ");
}

/**
 * Last-line scrub for text LEAVING THE DEVICE (remote-log `message`/`stack`).
 *
 * The call-site rule is still `noteRef(path)` and `errMsg(e, path)`; this is the
 * guarantee for the sites that forget. It is deliberately more aggressive than
 * `errMsg`'s fallback (see "Why there is no unquoted-path heuristic" above): it
 * only runs on egress, where losing a token is cheap and leaking one is not, and
 * every rule is linear so neither the old ReDoS nor its route-eating applies.
 *
 * Remaining honest gap: a spaced title at the vault ROOT with no slash anywhere
 * (`Divorce settlement draft.md`) leaks all but its last word — there is no
 * folder token to anchor the span on. `knownPath` at the call site is the fix.
 */
export function scrubLogText(text: string): string {
	return text
		.replace(EGRESS_QUOTED, redactQuoted)
		.replace(HOME_OR_DRIVE_PATH, (m) => (m.endsWith(" ") ? "<path> " : "<path>"))
		.split("\n")
		.map(redactSpacedPaths)
		.join("\n");
}

/**
 * Reduce a stack to its frames. A V8 stack's header is `Name: <message>` —
 * the raw, unscrubbed error message, which is exactly where an fs error puts
 * the absolute path. Keep only the error name, then the frames, then scrub the
 * frames too. JSC (iOS) stacks have no header and pass through the scrub.
 */
