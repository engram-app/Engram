const RANK: Record<AccessLevel, number> = { none: 0, read: 1, write: 2 };

// The level a request (or an echo) gives `id`. Neither field present is the
// pre-levels "every vault, write"; a list without a policy leaves the rest at none.
function levelIn(access: AccessRequest, id: string | null): AccessLevel {
	if (!(access.vault_access || access.default_access)) {
		return "write";
	}
	return (id && access.vault_access?.[id]) || access.default_access || "none";
}

export interface AccessRequest {
	vault_access?: Record<string, AccessLevel>;
	default_access?: AccessLevel;
}

// What a connection or API key may do in one vault (#174, #332). Mirrors
// `Engram.Permissions` levels on the backend.
export type AccessLevel = "none" | "read" | "write";

// A grant that asked for `mcp:read` and not `mcp`: it can never be given write.
// Mirrors Engram.OAuth.read_only_scope?/1.
export function isReadOnlyScope(scope: string): boolean {
	const parts = scope.split(" ");
	return parts.includes("mcp:read") && !parts.includes("mcp");
}

// The Read only shortcut and an `mcp:read` client both cap every level at read.
export function capLevel(level: AccessLevel, max: "read" | "write"): AccessLevel {
	return max === "read" && level === "write" ? "read" : level;
}

// Whether the backend's echo of a grant or key gives no vault more than the
// request did: every vault the user has now, every vault either side names,
// and (as `null`) every vault created later. A missing echo fails: the
// backend may have ignored the levels and granted everything.
export function grantWithin(
	granted: AccessRequest | undefined,
	requested: AccessRequest,
	vaultIds: string[],
): boolean {
	if (!(granted?.vault_access && granted.default_access)) {
		return false;
	}
	const ids = new Set([
		...vaultIds,
		...Object.keys(granted.vault_access),
		...Object.keys(requested.vault_access ?? {}),
	]);
	return [...ids, null].every((id) => RANK[levelIn(granted, id)] <= RANK[levelIn(requested, id)]);
}
