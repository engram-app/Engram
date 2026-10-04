/**
 * Encode each path segment but keep the slashes, so Phoenix's splat routes match.
 * encodeURIComponent on a whole path gives %2F, which Plug.Static rejects with a
 * 400 InvalidPathError before the router runs.
 */
export function encodePathSegments(path: string): string {
	return path.split("/").map(encodeURIComponent).join("/");
}
