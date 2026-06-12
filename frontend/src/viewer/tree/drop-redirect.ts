export interface DropSource {
  id: string
  parentId: string | undefined
}

/**
 * Resolve a headless-tree drop into a reparent move, or `null` for a no-op.
 *
 * Engram has no persisted custom order, so insertion position is ignored and
 * every drop is "move into the destination container". `destId` is
 * `target.item.getId()` from HT — always a folder marker id (`f:<id>`) or the
 * root id. The backend move endpoints can't target the vault root, so a root
 * (or missing) destination is a no-op; so is a drop whose sources already live
 * in `destId`.
 */
export function resolveDropMove(
  sources: DropSource[],
  destId: string | undefined,
  rootId: string,
): { dest: string; ids: string[] } | null {
  if (destId == null || destId === rootId) return null
  const ids = sources.filter((s) => s.parentId !== destId).map((s) => s.id)
  if (ids.length === 0) return null
  return { dest: destId, ids }
}
