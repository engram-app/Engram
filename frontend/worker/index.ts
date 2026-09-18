// app.engram.page edge Worker.
//
// The SPA itself is served as pure static assets — this Worker runs ONLY for
// the dead pre-eject MCP path and the first-party PostHog proxy, both scoped
// via `assets.run_worker_first` in wrangler.jsonc. Every other request keeps
// the fast asset path + SPA fallback and never invokes this code.
//
// Before the frontend eject, MCP clients paired against
// `app.engram.page/api/mcp`. After the Cloudflare Worker cutover that path is
// shadowed by the asset route and would otherwise return the SPA's index.html
// with a 200 — an HTML body to a JSON-RPC client, which fails opaquely.
// Return an explicit 410 Gone pointing at the new host so stale clients fail
// loudly and re-pair against `mcp.engram.page`.

const NEW_MCP_ENDPOINT = "https://mcp.engram.page/api/mcp";

const POSTHOG_HOST = "https://us.i.posthog.com";

// This header set is ported from engram-marketing/src/lib/posthog-proxy.ts
// verbatim — keep the two in sync. Strips IP-bearing and high-resolution geo
// headers before forwarding; `cf-ipcountry` intentionally passes through,
// since country-level is the granularity our privacy policy promises.
const STRIPPED_REQUEST_HEADERS = new Set([
	"host",
	"cookie",
	"cf-connecting-ip",
	"x-forwarded-for",
	"x-forwarded-host",
	"x-real-ip",
	"true-client-ip",
	"cf-ipcity",
	"cf-iplatitude",
	"cf-iplongitude",
	"cf-ipcontinent",
	"cf-iptimezone",
	"cf-region",
	"cf-region-code",
	"cf-postal-code",
]);

interface Env {
	ASSETS: { fetch: (request: Request) => Promise<Response> };
}

async function proxyToPostHog(request: Request): Promise<Response> {
	// Global Privacy Control has legal force under CCPA/CPRA and is what our
	// privacy policy promises to honor. This check does NOT exist in
	// engram-marketing's proxy (posthog-proxy.ts has no sec-gpc handling) —
	// this app's proxy is strictly stricter on this point, not a mirror of it.
	if (request.headers.get("sec-gpc") === "1") {
		return new Response(null, { status: 204, headers: { "cache-control": "no-store" } });
	}

	const url = new URL(request.url);
	const target = `${POSTHOG_HOST}${url.pathname.replace(/^\/ph/, "")}${url.search}`;

	const headers = new Headers();
	for (const [key, value] of request.headers) {
		if (!STRIPPED_REQUEST_HEADERS.has(key.toLowerCase())) {
			headers.set(key, value);
		}
	}

	const upstream = await fetch(
		new Request(target, {
			method: request.method,
			headers,
			body:
				request.method === "GET" || request.method === "HEAD"
					? undefined
					: await request.arrayBuffer(),
		}),
	);

	const responseHeaders = new Headers();
	upstream.headers.forEach((value, key) => {
		const k = key.toLowerCase();
		if (k === "content-type" || k === "content-length" || k === "access-control-allow-origin") {
			responseHeaders.set(key, value);
		}
	});
	responseHeaders.set("cache-control", "no-store");

	return new Response(upstream.body, { status: upstream.status, headers: responseHeaders });
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const { pathname } = new URL(request.url);

		if (pathname === "/ph" || pathname.startsWith("/ph/")) {
			return await proxyToPostHog(request);
		}

		if (pathname === "/api/mcp" || pathname.startsWith("/api/mcp/")) {
			return Response.json(
				{
					error: "gone",
					message: `The MCP endpoint moved to ${NEW_MCP_ENDPOINT}. Re-pair your client against the new host.`,
					endpoint: NEW_MCP_ENDPOINT,
				},
				{ status: 410, headers: { "cache-control": "no-store" } },
			);
		}

		// Defensive fallthrough: anything else that reaches the Worker is served
		// from static assets. With the scoped `run_worker_first` this is only hit
		// if the route list ever widens.
		return await env.ASSETS.fetch(request);
	},
};
