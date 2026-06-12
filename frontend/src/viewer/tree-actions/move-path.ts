/**
 * Move-target validation + new-path arithmetic for the folder tree.
 *
 * Pure path utilities used by the Move dialog to filter destination
 * folders and compute resulting paths. No DnD / React concerns.
 */

export type MoveNode = { kind: 'file' | 'folder'; path: string }

/**
 * Returns true iff `node` can be moved into `targetFolder`.
 *
 * Rejects:
 *  - moving a folder into itself
 *  - moving a folder into one of its own descendants
 *  - a no-op file move (file already lives in the target folder)
 */
export function isValidMoveTarget(node: MoveNode, targetFolder: string): boolean {
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
 * Callers are expected to gate on `isValidMoveTarget` first; this function
 * does no validation and will happily produce a path equal to the source
 * if the move is a no-op.
 */
export function newPathAfterMove(srcPath: string, targetFolder: string): string {
  const name = srcPath.split('/').pop() ?? srcPath
  return targetFolder === '' ? name : `${targetFolder}/${name}`
}
