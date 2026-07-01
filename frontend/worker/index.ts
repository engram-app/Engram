// app.engram.page edge Worker.
//
// The SPA itself is served as pure static assets — this Worker runs ONLY for
// the dead pre-eject MCP path, scoped via `assets.run_worker_first` in
// wrangler.jsonc. Every other request keeps the fast asset path + SPA
// fallback and never invokes this code.
//
// Before the frontend eject, MCP clients paired against
// `app.engram.page/api/mcp`. After the Cloudflare Worker cutover that path is
// shadowed by the asset route and would otherwise return the SPA's index.html
// with a 200 — an HTML body to a JSON-RPC client, which fails opaquely.
// Return an explicit 410 Gone pointing at the new host so stale clients fail
// loudly and re-pair against `mcp.engram.page`.

const NEW_MCP_ENDPOINT = "https://mcp.engram.page/api/mcp";

interface Env {
	ASSETS: { fetch: (request: Request) => Promise<Response> };
}

export default {
	async fetch(request: Request, env: Env): Promise<Response> {
		const { pathname } = new URL(request.url);

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
		return env.ASSETS.fetch(request);
	},
};
