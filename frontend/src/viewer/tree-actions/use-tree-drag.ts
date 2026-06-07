/**
 * Drop-target validation + new-path arithmetic for the folder tree.
 *
 * This module owns the validation logic only (pure path arithmetic).
 * DnD event wiring lives in the tree component itself (Task 13).
 */

export type DragNode = { kind: 'file' | 'folder'; path: string }

/**
 * Returns true iff `node` can be dropped into `targetFolder`.
 *
 * Rejects:
 *  - dropping a folder onto itself
 *  - dropping a folder into one of its own descendants
 *  - a no-op file move (file already lives in the target folder)
 */
export function isValidDropTarget(node: DragNode, targetFolder: string): boolean {
  if (node.kind === 'folder') {
    if (node.path === targetFolder) return false
    if (targetFolder.startsWith(`${node.path}/`)) return false
  }
  const currentFolder = node.path.includes('/')
    ? node.path.slice(0, node.path.lastIndexOf('/'))
    : ''
  if (node.kind === 'file' && currentFolder === targetFolder) return false
  return true
}

/**
 * Computes the new path of a node after a move into `targetFolder`.
 *
 * Callers are expected to gate on `isValidDropTarget` first; this function
 * does no validation and will happily produce a path equal to the source
 * if the move is a no-op.
 */
export function newPathAfterMove(srcPath: string, targetFolder: string): string {
  const name = srcPath.split('/').pop() ?? srcPath
  return targetFolder === '' ? name : `${targetFolder}/${name}`
}
