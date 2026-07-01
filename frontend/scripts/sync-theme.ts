#!/usr/bin/env bun
/* Pulls the canonical brand palette + assets from the marketing site into the app.
 *
 * engram-marketing owns the "Cyber-Organic" design language (its
 * src/styles/global.css :root/.dark blocks + scripts/convert-stitch-tokens.ts).
 * This app is a downstream consumer: run this on demand whenever marketing's
 * tokens or mark change. No CI gate — deliberately manual.
 *
 * Run:  bun scripts/sync-theme.ts [--dry-run] [--source <marketing-repo-dir>]
 * Env:  ENGRAM_MARKETING_DIR=<marketing-repo-dir>
 *
 * The name mapping is NOT identity: marketing's --secondary is the purple accent,
 * which lands in the app's --brand-purple. The app's own --secondary is a neutral
 * shadcn surface and is intentionally never touched here.
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { formatHex, parse } from "culori";

/* marketing var -> app var. Several app vars derive from one marketing var
 * (--input mirrors --border, --ring mirrors marketing --ring). App-only tokens
 * (--secondary*, --popover*, --chart-*, --sidebar-*, --radius) are absent here
 * by design, so the rewrite leaves them alone. */
const TOKEN_MAP: ReadonlyArray<readonly [marketing: string, app: string]> = [
	["bg", "background"],
	["fg", "foreground"],
	["muted", "muted"],
	["muted-fg", "muted-foreground"],
	["card", "card"],
	["card-fg", "card-foreground"],
	["primary", "primary"],
	["primary-fg", "primary-foreground"],
	["secondary", "brand-purple"],
	["secondary-fg", "brand-purple-foreground"],
	["accent", "accent"],
	["accent-fg", "accent-foreground"],
	["border", "border"],
	["border", "input"],
	["ring", "ring"],
	["destructive", "destructive"],
];

const ASSETS = ["engram-mark.svg", "favicon.svg"] as const;

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));

function findMarketingDir(): string {
	const flagIdx = process.argv.indexOf("--source");
	const fromFlag = flagIdx >= 0 ? process.argv[flagIdx + 1] : undefined;
	const candidate = fromFlag ?? process.env.ENGRAM_MARKETING_DIR;
	if (candidate) {
		if (!existsSync(join(candidate, "src/styles/global.css"))) {
			die(`--source/ENGRAM_MARKETING_DIR has no src/styles/global.css: ${candidate}`);
		}
		return candidate;
	}
	// Walk up from this script until a sibling engram-marketing checkout appears.
	let dir = SCRIPT_DIR;
	while (true) {
		const guess = join(dir, "engram-marketing");
		if (existsSync(join(guess, "src/styles/global.css"))) {
			return guess;
		}
		const parent = dirname(dir);
		if (parent === dir) {
			break;
		}
		dir = parent;
	}
	die(
		"Could not locate the engram-marketing checkout. Pass --source <dir> or set ENGRAM_MARKETING_DIR.",
	);
}

function die(msg: string): never {
	console.error(`sync-theme: ${msg}`);
	process.exit(1);
}

/* Returns the body of the first `<selector> { ... }` block whose declarations
 * include `mustContain`. These are flat declaration blocks (no nested braces),
 * so the first closing brace ends the block. */
function blockBody(css: string, selector: string, mustContain: string): string {
	const re = new RegExp(`${selector.replace(".", "\\.")}\\s*\\{`, "gu");
	let m: RegExpExecArray | null;
	while ((m = re.exec(css))) {
		const start = m.index + m[0].length;
		const end = css.indexOf("}", start);
		if (end === -1) {
			continue;
		}
		const body = css.slice(start, end);
		if (body.includes(mustContain)) {
			return body;
		}
	}
	die(`no '${selector}' block containing '${mustContain}'`);
}

function parseVars(body: string): Map<string, string> {
	const out = new Map<string, string>();
	for (const m of body.matchAll(/--([\w-]+):\s*([^;]+);/gu)) {
		out.set(m[1], m[2].trim());
	}
	return out;
}

interface Change {
	scope: string;
	appVar: string;
	from: string;
	to: string;
}

/* Rewrite the mapped app vars inside one app block to the marketing values.
 * Only existing declarations are touched; unmapped lines pass through verbatim. */
function rewriteBlock(
	fullCss: string,
	selector: string,
	appBody: string,
	marketingVars: Map<string, string>,
	scope: string,
	changes: Change[],
): string {
	let newBody = appBody;
	for (const [mktVar, appVar] of TOKEN_MAP) {
		const value = marketingVars.get(mktVar);
		if (value === undefined) {
			continue;
		}
		const decl = new RegExp(`(--${appVar}:\\s*)([^;]+)(;)`);
		const found = decl.exec(newBody);
		if (!found) {
			continue; // app-only target not present in this block
		}
		const current = found[2].trim();
		if (current === value) {
			continue;
		}
		changes.push({ scope, appVar, from: current, to: value });
		newBody = newBody.replace(decl, `$1${value}$3`);
	}
	return fullCss.replace(appBody, newBody);
}

function syncAssets(marketingDir: string, appPublic: string, dryRun: boolean): string[] {
	const actions: string[] = [];
	for (const name of ASSETS) {
		const src = join(marketingDir, "public", name);
		const dst = join(appPublic, name);
		if (!existsSync(src)) {
			console.warn(`sync-theme: marketing asset missing, skipped: ${name}`);
			continue;
		}
		const srcBuf = readFileSync(src);
		const same = existsSync(dst) && Buffer.compare(srcBuf, readFileSync(dst)) === 0;
		if (same) {
			continue;
		}
		actions.push(name);
		if (!dryRun) {
			writeFileSync(dst, srcBuf);
		}
	}
	return actions;
}

/* Vendor the marketing repo's immutable legal sources (src/legal/*.md +
 * legal-manifest.json) into the app so signup can render the exact bytes it
 * hashes. Same byte-compare/idempotent copy as syncAssets; the files are
 * frozen by version, so a changed byte for an existing name would be a bug
 * upstream, not something to silently overwrite — but we mirror verbatim and
 * surface the copy in the summary either way. */
function syncLegal(marketingDir: string, appLegalDir: string, dryRun: boolean): string[] {
	const actions: string[] = [];
	const srcDir = join(marketingDir, "src/legal");
	if (!existsSync(srcDir)) {
		console.warn(`sync-theme: marketing src/legal missing, skipped legal sync: ${srcDir}`);
		return actions;
	}
	const names = readdirSync(srcDir).filter((n) => n.endsWith(".md") || n === "legal-manifest.json");
	for (const name of names) {
		const src = join(srcDir, name);
		const dst = join(appLegalDir, name);
		const srcBuf = readFileSync(src);
		const same = existsSync(dst) && Buffer.compare(srcBuf, readFileSync(dst)) === 0;
		if (same) {
			continue;
		}
		actions.push(name);
		if (!dryRun) {
			mkdirSync(appLegalDir, { recursive: true });
			writeFileSync(dst, srcBuf);
		}
	}
	return actions;
}

const EMAIL_TOKEN_MAP: ReadonlyArray<readonly [marketing: string, elixir: string]> = [
	["secondary", "brand_purple"],
	["secondary-fg", "brand_purple_fg"],
	["fg", "text_primary"],
	["muted-fg", "text_muted"],
	["card", "surface_card"],
];

const SURFACE_PAGE_HEX = "#f5f5f7"; // email background, not in marketing tokens

function oklchToHex(oklch: string): string {
	const parsed = parse(oklch);
	if (!parsed) {
		die(`could not parse oklch value: ${oklch}`);
	}
	const hex = formatHex(parsed);
	if (!hex) {
		die(`could not format hex for: ${oklch}`);
	}
	return hex.toLowerCase();
}

function emailTokensElixir(light: Map<string, string>): string {
	const lines: string[] = [];
	lines.push("defmodule Engram.Email.Tokens do");
	lines.push(`  @moduledoc """`);
	lines.push("  Generated from engram-marketing/src/styles/global.css :root block by");
	lines.push("  `bun scripts/sync-theme.ts`. Do not edit by hand.");
	lines.push("");
	lines.push("  Email clients support neither oklch() nor CSS custom properties, so the");
	lines.push("  marketing oklch values are resolved to sRGB hex at sync time.");
	lines.push(`  """`);
	lines.push("");
	for (const [mktVar, elixirFn] of EMAIL_TOKEN_MAP) {
		const oklch = light.get(mktVar);
		if (!oklch) {
			die(`marketing token missing: --${mktVar}`);
		}
		const hex = oklchToHex(oklch);
		lines.push(`  def ${elixirFn}, do: "${hex}"`);
	}
	lines.push(`  def surface_page, do: "${SURFACE_PAGE_HEX}"`);
	lines.push("end");
	lines.push("");
	return lines.join("\n");
}

function syncEmailTokens(
	light: Map<string, string>,
	appRoot: string,
	dryRun: boolean,
): string | null {
	const dest = join(appRoot, "lib/engram/email/tokens.ex");
	const next = emailTokensElixir(light);
	const current = existsSync(dest) ? readFileSync(dest, "utf8") : "";
	if (current === next) {
		return null;
	}
	if (!dryRun) {
		writeFileSync(dest, next);
	}
	return "lib/engram/email/tokens.ex";
}

function main() {
	const dryRun = process.argv.includes("--dry-run");
	const marketingDir = findMarketingDir();
	const appRoot = join(SCRIPT_DIR, "..");
	const marketingCss = readFileSync(join(marketingDir, "src/styles/global.css"), "utf8");
	const appCssPath = join(appRoot, "src/main.css");
	let appCss = readFileSync(appCssPath, "utf8");

	const light = parseVars(blockBody(marketingCss, ":root", "--bg"));
	const dark = parseVars(blockBody(marketingCss, ".dark", "--bg"));

	const changes: Change[] = [];
	// Re-derive each app body from the (possibly updated) css before rewriting it.
	appCss = rewriteBlock(
		appCss,
		":root",
		blockBody(appCss, ":root", "--background"),
		light,
		"light",
		changes,
	);
	appCss = rewriteBlock(
		appCss,
		".dark",
		blockBody(appCss, ".dark", "--background"),
		dark,
		"dark",
		changes,
	);

	const assetActions = syncAssets(marketingDir, join(appRoot, "public"), dryRun);
	const legalActions = syncLegal(marketingDir, join(appRoot, "src/legal/versions"), dryRun);
	const tokensAction = syncEmailTokens(light, join(appRoot, ".."), dryRun);

	console.log(`sync-theme: source = ${marketingDir}${dryRun ? "  (dry run)" : ""}`);
	for (const c of changes) {
		console.log(`  [${c.scope}] --${c.appVar}: ${c.from}  ->  ${c.to}`);
	}
	for (const a of assetActions) {
		console.log(`  [asset] ${a} ${dryRun ? "(would copy)" : "copied"}`);
	}
	for (const l of legalActions) {
		console.log(`  [legal] ${l} ${dryRun ? "(would copy)" : "copied"}`);
	}
	if (tokensAction) {
		console.log(`  [email-tokens] ${tokensAction} ${dryRun ? "(would write)" : "written"}`);
	}

	if (
		changes.length === 0 &&
		assetActions.length === 0 &&
		legalActions.length === 0 &&
		!tokensAction
	) {
		console.log("  already in sync");
		return;
	}
	const emailTokenCount = tokensAction ? 1 : 0;
	if (dryRun) {
		console.log(
			`sync-theme: ${changes.length} token change(s), ${assetActions.length} asset(s), ${legalActions.length} legal file(s), ${emailTokenCount} email-token file(s) pending`,
		);
	} else {
		writeFileSync(appCssPath, appCss);
		console.log(
			`sync-theme: wrote ${changes.length} token change(s), ${assetActions.length} asset(s), ${legalActions.length} legal file(s), ${emailTokenCount} email-token file(s)`,
		);
	}
}

main();
