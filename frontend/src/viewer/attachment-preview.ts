// Pure helpers behind the attachment page: which inline preview a file gets,
// whether its blob may open in a new tab, and the CSV/byte formatting the
// preview and file card render.

const TEXT_MIMES = new Set([
	"application/json",
	"application/ld+json",
	"application/xml",
	"application/yaml",
	"application/x-yaml",
	"application/toml",
	"application/javascript",
	"application/sql",
]);

// Mime first; the extension covers uploads typed application/octet-stream.
const TEXT_EXTS = new Set([
	"txt",
	"log",
	"json",
	"jsonl",
	"ndjson",
	"xml",
	"yaml",
	"yml",
	"toml",
	"ini",
	"cfg",
	"conf",
	"env",
	"properties",
	"html",
	"htm",
	"css",
	"scss",
	"less",
	"js",
	"mjs",
	"cjs",
	"ts",
	"tsx",
	"jsx",
	"py",
	"rb",
	"go",
	"rs",
	"java",
	"kt",
	"swift",
	"c",
	"h",
	"cpp",
	"hpp",
	"cs",
	"php",
	"lua",
	"r",
	"sql",
	"tex",
	"bib",
	"srt",
	"vtt",
	"diff",
	"patch",
	"ex",
	"exs",
	"erl",
	"hs",
	"ml",
	"clj",
	"dart",
	"scala",
	"vue",
	"svelte",
	"graphql",
	"proto",
	"dockerfile",
	"makefile",
	"gitignore",
	"editorconfig",
]);

const CSV_EXTS = new Set(["csv", "tsv"]);

function extOf(path: string): string {
	const name = (path.split("/").pop() ?? path).toLowerCase();
	const dot = name.lastIndexOf(".");
	// A dotfile (".gitignore") or a bare "Makefile" is its own extension.
	return dot <= 0 ? name.replace(/^\./u, "") : name.slice(dot + 1);
}

const UNITS = ["byte", "kilobyte", "megabyte", "gigabyte"] as const;

export type PreviewKind = "image" | "pdf" | "audio" | "video" | "csv" | "text";

// Text previews render only this much: a <pre> or table holding 100 MB of
// text freezes the tab. Everything else previews at any size.
export const TEXT_PREVIEW_MAX_BYTES = 2 * 1024 * 1024;

export function previewKind(path: string, mime: string): PreviewKind | null {
	const ext = extOf(path);
	let kind: PreviewKind | null = null;
	if (mime.startsWith("image/")) {
		kind = "image";
	} else if (mime === "application/pdf") {
		kind = "pdf";
	} else if (mime.startsWith("audio/")) {
		kind = "audio";
	} else if (mime.startsWith("video/")) {
		kind = "video";
	} else if (CSV_EXTS.has(ext) || mime === "text/csv" || mime === "text/tab-separated-values") {
		kind = "csv";
	} else if (mime.startsWith("text/") || TEXT_MIMES.has(mime) || TEXT_EXTS.has(ext)) {
		kind = "text";
	}
	return kind;
}

// A blob: URL runs in OUR origin, so opening an HTML or SVG blob in a tab would
// execute the file's script with the user's session. Allow only types the
// browser renders without script.
export function opensInline(mime: string): boolean {
	if (mime === "image/svg+xml") {
		return false;
	}
	return (
		mime === "application/pdf" ||
		mime.startsWith("audio/") ||
		mime.startsWith("video/") ||
		mime.startsWith("image/")
	);
}

// RFC 4180-ish: quoted cells may hold the delimiter, newlines and "" escapes.
// Stops after `maxRows` so a large file renders a bounded table.
export function parseCsv(text: string, delimiter: string, maxRows: number): string[][] {
	const rows: string[][] = [];
	let row: string[] = [];
	let cell = "";
	let quoted = false;
	for (let i = 0; i < text.length && rows.length < maxRows; i++) {
		const ch = text[i];
		if (quoted) {
			if (ch === '"' && text[i + 1] === '"') {
				cell += '"';
				i++;
			} else if (ch === '"') {
				quoted = false;
			} else {
				cell += ch;
			}
		} else if (ch === '"' && cell === "") {
			quoted = true;
		} else if (ch === delimiter) {
			row.push(cell);
			cell = "";
		} else if (ch === "\n" || ch === "\r") {
			if (ch === "\r" && text[i + 1] === "\n") {
				i++;
			}
			row.push(cell);
			rows.push(row);
			row = [];
			cell = "";
		} else {
			cell += ch;
		}
	}
	if (rows.length < maxRows && (cell !== "" || row.length > 0)) {
		row.push(cell);
		rows.push(row);
	}
	return rows;
}

export function formatBytes(bytes: number, locale?: string): string {
	let value = bytes;
	let unit = 0;
	while (value >= 1024 && unit < UNITS.length - 1) {
		value /= 1024;
		unit++;
	}
	return new Intl.NumberFormat(locale, {
		style: "unit",
		unit: UNITS[unit],
		maximumFractionDigits: unit === 0 ? 0 : 1,
	}).format(value);
}

// "report.final.pdf" -> { stem: "report.final", ext: ".pdf" }. A dotfile or a
// bare name has no extension.
export function fileStem(path: string): { stem: string; ext: string } {
	const name = path.split("/").pop() ?? path;
	const dot = name.lastIndexOf(".");
	return dot <= 0 ? { stem: name, ext: "" } : { stem: name.slice(0, dot), ext: name.slice(dot) };
}

// Rename keeps the folder and the extension; only the stem changes, so a file
// cannot become a different type by rename. Null = nothing to send.
export function attachmentRenamePath(path: string, nextStem: string): string | null {
	const { stem, ext } = fileStem(path);
	let next = nextStem.trim();
	if (ext && next.toLowerCase().endsWith(ext.toLowerCase())) {
		next = next.slice(0, -ext.length);
	}
	if (!next || next.includes("/") || next === stem) {
		return null;
	}
	const folder = path.includes("/") ? path.slice(0, path.lastIndexOf("/") + 1) : "";
	return `${folder}${next}${ext}`;
}
