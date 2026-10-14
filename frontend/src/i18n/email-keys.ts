// The backend's email strings, for the same translategemma run as the web app.
// Keys are English sentences in Elixir source (`EMAIL_SOURCES`: translate calls
// with the locale first and a literal key) plus the legal changelogs in the
// seeder. Catalogs go to `priv/i18n/email/<locale>.json`, read at compile time
// by `Engram.I18n`. Pure: callers supply the source text.
import type { Entry } from "./keys-scan";

// Elixir and JSON escape a double-quoted string the same way for plain text.
const STRING = String.raw`"(?<key>(?:[^"\\]|\\.)*)"`;
const PATTERNS = [
	new RegExp(String.raw`\bt\(\s*\w+,\s*${STRING}`, "gu"),
	new RegExp(String.raw`\bchangelog:\s*${STRING}`, "gu"),
];

// Whole-line `#` comments, but not a heredoc line opening with `#{...}`.
const COMMENT = /^\s*#(?!\{).*$/gmu;

const EMAIL_SOURCES = [
	"lib/engram/mailer.ex",
	"lib/engram/email/template.ex",
	"lib/engram/legal/seeder.ex",
] as const;

function emailEntries(sources: readonly string[]): Entry[] {
	const keys = new Set<string>();
	for (const source of sources) {
		const code = source.replace(COMMENT, "");
		for (const re of PATTERNS) {
			for (const match of code.matchAll(re)) {
				const key: unknown = JSON.parse(`"${match.groups?.key ?? ""}"`);
				if (typeof key === "string" && key !== "") {
					keys.add(key);
				}
			}
		}
	}
	return [...keys].map((key) => ({ key }));
}

export { EMAIL_SOURCES, emailEntries };
