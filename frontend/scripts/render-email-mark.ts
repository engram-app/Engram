#!/usr/bin/env bun
/* One-shot: rasterize the brand mark SVG to a PNG suitable for email clients.
 * The output PNG is committed; this script does NOT run in CI. Re-run it only
 * when public/engram-mark.svg changes.
 *
 * Pipeline: SVG -> resvg (truecolor PNG) -> pngquant --quality=95-100
 * (palette-quantized PNG). Quantization at 95-100 is visually lossless on the
 * flat-fill brand mark and trims ~58% off the file size.
 *
 * pngquant-bin's postinstall is deliberately NOT in trustedDependencies (its
 * GitHub binary download 429s on the shared-egress CI runners and the source
 * fallback needs pkg-config/libimagequant — issue #975). Before running this
 * script, fetch the binary once with:
 *   bun pm trust pngquant-bin && bun install
 */
import { execFileSync } from "node:child_process";
import { readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Resvg } from "@resvg/resvg-js";
import pngquant from "pngquant-bin";

const HERE = dirname(fileURLToPath(import.meta.url));
const appRoot = join(HERE, "..");
const dest = join(appRoot, "..", "priv/static/email/engram-mark.png");

const svg = readFileSync(join(appRoot, "public/engram-mark.svg"));
const truecolor = new Resvg(svg, { fitTo: { mode: "width", value: 256 } }).render().asPng();

const tmp = `${dest}.truecolor.tmp`;
writeFileSync(tmp, truecolor);
try {
	execFileSync(pngquant, [
		"--quality=95-100",
		"--speed=1",
		"--strip",
		"--force",
		"--output",
		dest,
		tmp,
	]);
} finally {
	unlinkSync(tmp);
}

const finalSize = readFileSync(dest).byteLength;
console.log(
	`wrote ${finalSize} bytes -> ${dest} ` +
		`(${truecolor.byteLength} truecolor -> ${finalSize} quantized, ` +
		`${Math.round((1 - finalSize / truecolor.byteLength) * 100)}% smaller)`,
);
