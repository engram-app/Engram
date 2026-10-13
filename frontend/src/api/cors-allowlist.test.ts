import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

// Prod is cross-origin (app.engram.page -> api.engram.page), so every request
// header the SPA sets must be in the backend's CORS allowlist or the browser
// blocks the preflight. Same-origin dev and e2e never exercise that, which is
// how X-Idempotency-Key shipped missing and broke folder delete in prod.
//
// ponytail: source scan for quoted `X-*` / `traceparent` literals; a header
// name built at runtime would slip past. Switch to a shared header manifest if
// that ever happens.
const SRC = join(__dirname, "..");
const CORS_PLUG = join(__dirname, "../../../lib/engram_web/plugs/cors.ex");

function allowedHeaders(): Set<string> {
	const plug = readFileSync(CORS_PLUG, "utf8");
	const match = plug.match(/"access-control-allow-headers",\s*"(?<list>[^"]+)"/);
	const list = match?.groups?.list;
	if (!list) {
		throw new Error("allow-headers list not found in cors.ex");
	}
	return new Set(list.split(",").map((h) => h.trim().toLowerCase()));
}

function headersTheSpaSends(): Set<string> {
	const found = new Set<string>();
	for (const file of readdirSync(SRC, { recursive: true, encoding: "utf8" })) {
		if (!/\.tsx?$/.test(file) || /\.test\.tsx?$/.test(file)) {
			continue;
		}
		const text = readFileSync(join(SRC, file), "utf8");
		for (const m of text.matchAll(/["'](?<name>X-[A-Za-z0-9-]+|traceparent)["']/g)) {
			found.add((m.groups?.name ?? "").toLowerCase());
		}
	}
	return found;
}

describe("CORS allowlist covers every header the SPA sends", () => {
	it("finds the headers it is meant to guard", () => {
		// Guards the scan itself: an empty set would pass vacuously.
		expect([...headersTheSpaSends()]).toEqual(
			expect.arrayContaining(["x-vault-id", "x-device-id", "x-idempotency-key"]),
		);
	});

	it("allows each one in the preflight", () => {
		const allowed = allowedHeaders();
		const missing = [...headersTheSpaSends()].filter((h) => !allowed.has(h));
		expect(missing).toEqual([]);
	});
});
