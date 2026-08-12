import type { CompletionResult, CompletionSource } from "@codemirror/autocomplete";

// Obsidian-style `[[` autocomplete, fed by the cached sync manifest
// (path -> note id inventory; see api/queries.ts's useSyncManifest). Pure
// ranking lives here so it's testable without a CodeMirror instance; the CM6
// wiring (wikiCompletionSource) is a thin adapter over it.

function basename(path: string): string {
	const stem = path.replace(/\.md$/iu, "");
	return stem.split("/").at(-1) ?? stem;
}

const MAX_CANDIDATES = 50;

function dirname(path: string): string {
	const idx = path.lastIndexOf("/");
	return idx === -1 ? "" : path.slice(0, idx);
}

export interface WikiCompletionCandidate {
	/** Basename, extension stripped -- what the user sees and what the [[ ]] apply() inserts. */
	label: string;
	/**
	 * Full vault path as stored. The markdown-link apply() inserts this rather
	 * than the label: `[text](target)` is resolved by resolveWikiTarget's
	 * exact-path branch, and a basename shared by two notes would otherwise
	 * silently resolve to whichever has the shorter path.
	 */
	path: string;
	/**
	 * Folder path (path minus filename), empty for root notes. Rendered as the
	 * muted second line of the row, Obsidian-style; disambiguates same-named
	 * notes in different folders.
	 */
	detail: string;
}

/**
 * Rank: basename prefix match, then basename substring match, then path
 * substring match. Case-insensitive throughout. Capped at MAX_CANDIDATES.
 */
export function wikiCompletionCandidates(
	query: string,
	paths: string[],
): WikiCompletionCandidate[] {
	const q = query.toLowerCase();
	const prefix: WikiCompletionCandidate[] = [];
	const basenameSubstring: WikiCompletionCandidate[] = [];
	const pathSubstring: WikiCompletionCandidate[] = [];
	for (const path of paths) {
		const label = basename(path);
		const labelLower = label.toLowerCase();
		if (labelLower.startsWith(q)) {
			prefix.push({ label, path, detail: dirname(path) });
		} else if (labelLower.includes(q)) {
			basenameSubstring.push({ label, path, detail: dirname(path) });
		} else if (path.toLowerCase().includes(q)) {
			pathSubstring.push({ label, path, detail: dirname(path) });
		}
	}
	return [...prefix, ...basenameSubstring, ...pathSubstring].slice(0, MAX_CANDIDATES);
}

// Fires on an open `[[` with no closing bracket, alias pipe, or heading `#`
// between it and the cursor -- i.e. exactly the partial-target position.
// `[^\][|#]*$` (not `.*$`) is what keeps this from matching to the RIGHT of
// an already-closed link like "[[done]] Al", and from firing inside an alias
// segment ("[[a|b") where Obsidian doesn't offer target completion either.
export const WIKI_TRIGGER_RE = /\[\[(?<target>[^\][|#]*)$/;

// The same picker inside a markdown link's `(target)`. Unlike the wikilink
// trigger this ALLOWS spaces -- note names routinely contain them, and stopping
// at the first space would close the popup halfway through "Gamma Ray". A `)`
// still terminates it, which is what keeps this from matching to the right of
// an already-closed "[a](b)".
export const MD_LINK_TRIGGER_RE = /\]\((?<target>[^)]*)$/;

/**
 * CM6 completion source. `getPaths` is called on every keystroke (not cached
 * here) so it must be cheap -- NotePage passes a ref read, not a fetch.
 */
export function wikiCompletionSource(getPaths: () => string[]): CompletionSource {
	return (context): CompletionResult | null => {
		const match = context.matchBefore(WIKI_TRIGGER_RE);
		if (!match) {
			return null;
		}
		// match.text is the WHOLE trigger, "[[" included; the target starts
		// right after it.
		const from = match.from + 2;
		const target = match.text.slice(2);
		const candidates = wikiCompletionCandidates(target, getPaths());
		return {
			from,
			options: candidates.map((c) => ({
				label: c.label,
				// Root notes have no folder line; omit so CM6 renders no detail span.
				...(c.detail ? { detail: c.detail } : {}),
				apply: (view, completion, applyFrom, applyTo) => {
					// Obsidian auto-pairs "[[" with "]]", so the closing brackets
					// often already sit right after the cursor -- don't double them.
					// A directly-following "|alias]]" or "#heading]]" tail also means
					// the link is already closed further along, just not immediately.
					const nextChar = view.state.doc.sliceString(applyTo, applyTo + 1);
					const alreadyClosed =
						view.state.doc.sliceString(applyTo, applyTo + 2) === "]]" ||
						nextChar === "|" ||
						nextChar === "#";
					const insert = alreadyClosed ? completion.label : `${completion.label}]]`;
					view.dispatch({
						changes: { from: applyFrom, to: applyTo, insert },
						// Land right after the target, before "]]", so typing "|alias"
						// or arrowing past the brackets both work naturally.
						selection: { anchor: applyFrom + completion.label.length },
					});
				},
			})),
		};
	};
}

/**
 * Same picker, fired inside a markdown link's `(target)`. Registered alongside
 * wikiCompletionSource rather than folded into it: the two differ in what they
 * insert (encoded full path vs basename) and in how they close (`)` vs `]]`),
 * so one source with two branches would be harder to read than two sources.
 */
export function mdLinkCompletionSource(getPaths: () => string[]): CompletionSource {
	return (context): CompletionResult | null => {
		const match = context.matchBefore(MD_LINK_TRIGGER_RE);
		if (!match) {
			return null;
		}
		// match.text is the whole trigger, "](" included.
		const from = match.from + 2;
		const candidates = wikiCompletionCandidates(match.text.slice(2), getPaths());
		return {
			from,
			options: candidates.map((c) => ({
				label: c.label,
				...(c.detail ? { detail: c.detail } : {}),
				apply: (view, _completion, applyFrom, applyTo) => {
					// A raw space is not a legal markdown destination — CommonMark
					// stops parsing the link at it — so encode before inserting.
					const insert = encodeURI(c.path);
					const alreadyClosed = view.state.doc.sliceString(applyTo, applyTo + 1) === ")";
					view.dispatch({
						changes: {
							from: applyFrom,
							to: applyTo,
							insert: alreadyClosed ? insert : `${insert})`,
						},
						// Before the ")", so the cursor is where you'd keep typing.
						selection: { anchor: applyFrom + insert.length },
					});
				},
			})),
		};
	};
}
