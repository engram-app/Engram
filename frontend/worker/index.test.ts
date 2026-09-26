// @vitest-environment node
//
// Real fetch/Request/Headers, unlike happy-dom (the repo default), which
// silently strips forbidden "Sec-*" request headers — this test needs
// Sec-GPC to actually land on the constructed Request.
import { afterEach, describe, expect, it, vi } from "vitest";
import worker from "./index";

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
