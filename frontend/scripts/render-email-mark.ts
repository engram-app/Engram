#!/usr/bin/env bun
/* One-shot: rasterize the brand mark SVG to a PNG suitable for email clients.
 * The output PNG is committed; this script does NOT run in CI. Re-run it only
 * when public/engram-mark.svg changes.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { Resvg } from "@resvg/resvg-js";

const HERE = dirname(fileURLToPath(import.meta.url));
const appRoot = join(HERE, "..");
const svg = readFileSync(join(appRoot, "public/engram-mark.svg"));
const png = new Resvg(svg, { fitTo: { mode: "width", value: 256 } })
  .render()
  .asPng();
const dest = join(appRoot, "..", "priv/static/email/engram-mark.png");
writeFileSync(dest, png);
console.log(`wrote ${png.byteLength} bytes -> ${dest}`);
