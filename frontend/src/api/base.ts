import { useConfig } from "@/config-context";

// Combines the configured apiBase with a path. Strips the `/api` prefix
// on saas (where apiBase = `https://api.engram.page` and the host-rewrite
// plug prefixes `/api` server-side) and keeps it on selfhost (apiBase
// = "", same-origin Phoenix-hosted SPA).
export function joinApiUrl(apiBase: string, path: string): string {
	if (!apiBase) return path;
	const stripped = path.startsWith("/api/") ? path.slice(4) : path;
	return apiBase + stripped;
}

export function joinWsUrl(wsBase: string, path: string): string {
	return wsBase ? wsBase + path : path;
}

export function useApiUrl(): (path: string) => string {
	const { apiBase } = useConfig();
	return (path: string) => joinApiUrl(apiBase, path);
}

export function useWsUrl(): (path: string) => string {
	const { wsBase } = useConfig();
	return (path: string) => joinWsUrl(wsBase, path);
}

// Module-level base setters — parallel the existing setTokenGetter
// pattern in `./client`. `BootstrapGate` in main.tsx wires apiBase/wsBase
// inline from the resolved config so non-React utilities like the singleton
// `api` object and `connectChannel(...)` can compose URLs without dragging
// a hook dependency into every call site.
let _apiBase = "";
let _wsBase = "";

export function setApiBase(v: string) {
	_apiBase = v;
}

export function setWsBase(v: string) {
	_wsBase = v;
}

export function getApiBase(): string {
	return _apiBase;
}

export function getWsBase(): string {
	return _wsBase;
}
