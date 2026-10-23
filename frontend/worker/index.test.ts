// @vitest-environment node
//
// Real fetch/Request/Headers, unlike happy-dom (the repo default), which
// silently strips forbidden "Sec-*" request headers — this test needs
// Sec-GPC to actually land on the constructed Request.
import { afterEach, describe, expect, it, vi } from "vitest";
import worker, { APPLE_PAY_PATH } from "./index";

const envStub = {
	ASSETS: { fetch: vi.fn(async () => new Response("asset")) },
};

describe("worker /ph proxy", () => {
	afterEach(() => {
		vi.restoreAllMocks();
	});

	it("strips IP-bearing headers and passes cf-ipcountry", async () => {
		const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("ok"));
		await worker.fetch(
			new Request("https://app.engram.page/ph/capture/", {
				method: "POST",
				headers: { "cf-connecting-ip": "203.0.113.9", "cf-ipcountry": "DE", "cf-ipcity": "Berlin" },
				body: "{}",
			}),
			envStub,
		);

		const sent = fetchSpy.mock.calls[0][0] as Request;
		expect(sent.headers.get("cf-connecting-ip")).toBeNull();
		expect(sent.headers.get("cf-ipcity")).toBeNull();
		expect(sent.headers.get("cf-ipcountry")).toBe("DE");
	});

	it("returns 204 without forwarding when Sec-GPC is 1", async () => {
		const fetchSpy = vi.spyOn(globalThis, "fetch");
		const res = await worker.fetch(
			new Request("https://app.engram.page/ph/capture/", {
				method: "POST",
				headers: { "sec-gpc": "1" },
				body: "{}",
			}),
			envStub,
		);
		expect(res.status).toBe(204);
		expect(fetchSpy).not.toHaveBeenCalled();
	});

	it("still 410s the dead MCP path", async () => {
		const res = await worker.fetch(new Request("https://app.engram.page/api/mcp"), envStub);
		expect(res.status).toBe(410);
	});

	// Referrer-Policy: origin keeps the full URL out today; this is the backstop
	// if that header is ever loosened. A referer can carry the vault slug.
	it("strips the referer", async () => {
		const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("ok"));
		await worker.fetch(
			new Request("https://app.engram.page/ph/capture/", {
				method: "POST",
				headers: { referer: "https://app.engram.page/v/divorce-2026/abc" },
				body: "{}",
			}),
			envStub,
		);
		const sent = fetchSpy.mock.calls[0][0] as Request;
		expect(sent.headers.get("referer")).toBeNull();
	});
});

describe("worker /.well-known", () => {
	const assetsFetch = vi.fn<(request: Request) => Promise<Response>>();
	const env = { ASSETS: { fetch: assetsFetch } };

	afterEach(() => {
		assetsFetch.mockReset();
	});

	it("serves the Apple Pay association file as text/plain from static assets", async () => {
		assetsFetch.mockResolvedValue(
			new Response("7B227073704964...", {
				headers: { "content-type": "application/octet-stream" },
			}),
		);
		const res = await worker.fetch(new Request(`https://app.engram.page${APPLE_PAY_PATH}`), env);
		expect(res.status).toBe(200);
		expect(res.headers.get("content-type")).toBe("text/plain; charset=UTF-8");
		expect(await res.text()).toBe("7B227073704964...");
		expect(new URL(assetsFetch.mock.calls[0][0].url).pathname).toBe(APPLE_PAY_PATH);
	});

	// The original bug: the SPA fallback answered this path with index.html + 200.
	it("404s instead of serving the SPA shell if the asset is missing", async () => {
		assetsFetch.mockResolvedValue(
			new Response("<!doctype html>", { headers: { "content-type": "text/html" } }),
		);
		const res = await worker.fetch(new Request(`https://app.engram.page${APPLE_PAY_PATH}`), env);
		expect(res.status).toBe(404);
	});

	it("404s unknown /.well-known paths without touching the SPA fallback", async () => {
		for (const path of [
			"/.well-known/oauth-authorization-server",
			"/.well-known/",
			"/.well-known",
		]) {
			const res = await worker.fetch(new Request(`https://app.engram.page${path}`), env);
			expect(res.status).toBe(404);
		}
		expect(assetsFetch).not.toHaveBeenCalled();
	});

	it("ships the exact Paddle file and routes /.well-known through the Worker", async () => {
		const { readFileSync } = await import("node:fs");
		const { createHash } = await import("node:crypto");
		const file = readFileSync(new URL(`../public${APPLE_PAY_PATH}`, import.meta.url));
		expect(file.length).toBe(9094);
		expect(createHash("sha256").update(file).digest("hex")).toBe(
			"2de7b483319c713bf649352f7f158f1fedbda92f546bebfe576ae0a2d2c526c6",
		);
		const wrangler = readFileSync(new URL("../wrangler.jsonc", import.meta.url), "utf8");
		const runWorkerFirst = JSON.parse(
			wrangler.match(/"run_worker_first":\s*(?<list>\[[^\]]*\])/)?.groups?.list ?? "[]",
		);
		expect(runWorkerFirst).toEqual(expect.arrayContaining(["/.well-known", "/.well-known/*"]));
	});
});
