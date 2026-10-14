import type { QueryClient } from "@tanstack/react-query";
import { matchPath } from "react-router";
import { noteQueryOptions, vaultTreeQueryOptions } from "../api/queries";
import { VAULT_PREFIX } from "../routes";
import { preloadNoteChunks } from "../viewer/note-chunks";

/**
 * Start what the first screen needs alongside /bootstrap, not after it.
 *
 * Opening a note link used to run in series: /bootstrap, then (once the gate
 * rendered its children) the vault tree, then (once the route's lazy chunks
 * mounted NotePage) the note body. The note id is in the URL from the start,
 * so all three can go at once.
 *
 * Uses the vault remembered from last session. If /bootstrap then reconciles
 * to a different one, these land under keys nothing reads: a wasted request,
 * never a wrong one, since every key carries the vault id.
 */
export function prefetchFirstView(qc: QueryClient, pathname: string, vaultId: string | null): void {
	if (!(vaultId && matchPath({ path: `${VAULT_PREFIX}/:slug`, end: false }, pathname))) {
		return;
	}
	qc.prefetchQuery(vaultTreeQueryOptions(vaultId)).catch(() => undefined);
	const item = matchPath(`${VAULT_PREFIX}/:slug/:itemId`, pathname)?.params.itemId;
	if (item) {
		// An attachment id 404s here; the attachment page fetches its own.
		qc.prefetchQuery(noteQueryOptions(vaultId, item)).catch(() => undefined);
		preloadNoteChunks();
	}
}
