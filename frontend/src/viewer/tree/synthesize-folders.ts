import type { AttachmentSummary, Folder } from '../../api/queries'

// Synthetic folders (attachment-only dirs not in /api/folders) carry this id
// prefix. They have no backend record, so id-keyed backend calls (rename, move,
// delete, note-prefetch) must skip them — `isSyntheticFolderId` is the single
// home for that check.
const SYNTHETIC_ID_PREFIX = 'syn:'

export function isSyntheticFolderId(id: string): boolean {
  return id.startsWith(SYNTHETIC_ID_PREFIX)
}

// Folder dirs that exist only because they hold attachments aren't returned by
// /api/folders (folders are derived from notes + markers, not attachments).
// Synthesize them so every attachment is reachable in the tree. Real folders
// win their id; synthetic rows use `syn:<full-path>` ids and link to their
// parent (real or synthetic).
export function synthesizeFolders(
  real: Folder[],
  attachments: AttachmentSummary[],
): Folder[] {
  const byName = new Map<string, Folder>()
  for (const f of real) byName.set(f.name, f)

  // Collect every directory prefix from attachment paths.
  const dirs = new Set<string>()
  for (const a of attachments) {
    const slash = a.path.lastIndexOf('/')
    if (slash < 0) continue // root attachment — no folder needed
    const dir = a.path.slice(0, slash)
    const segments = dir.split('/')
    for (let i = 1; i <= segments.length; i++) dirs.add(segments.slice(0, i).join('/'))
  }

  // Synthesize missing dirs, shallow-first so parents exist before children.
  const sorted = [...dirs].sort((x, y) => x.split('/').length - y.split('/').length)
  for (const name of sorted) {
    if (byName.has(name)) continue
    const slash = name.lastIndexOf('/')
    const parentName = slash < 0 ? null : name.slice(0, slash)
    const parent = parentName == null ? null : (byName.get(parentName) ?? null)
    byName.set(name, {
      id: `${SYNTHETIC_ID_PREFIX}${name}`,
      parent_id: parent ? parent.id : null,
      name,
      count: 0,
    })
  }

  return [...byName.values()]
}
