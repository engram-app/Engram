import type { AttachmentSummary, Folder } from '../../api/queries'

// Synthetic folders (attachment-only dirs not in /api/folders) carry this id
// prefix. They have no backend record, so id-keyed backend calls (rename, move,
// delete, note-prefetch) must skip them — `isSyntheticFolderId` is the single
// home for that check.
const SYNTHETIC_ID_PREFIX = 'syn:'

export function isSyntheticFolderId(id: string): boolean {
  return id.startsWith(SYNTHETIC_ID_PREFIX)
}

// Stable id for a folder the backend returned with a null id (a derived folder)
// or one we synthesize as a missing ancestor. Keyed on the full path so the same
// folder always resolves to the same id across renders and across the two call
// sites (selectFolders seeding it, synthesizeFolders linking parents to it).
export function syntheticFolderId(name: string): string {
  return `${SYNTHETIC_ID_PREFIX}${name}`
}

// Recover the folder path encoded in a synthetic id (inverse of syntheticFolderId).
export function syntheticFolderPath(id: string): string {
  return id.slice(SYNTHETIC_ID_PREFIX.length)
}

// Reconstruct the full folder tree the UI needs from the backend's flat,
// incomplete list. `/api/folders` returns only leaf folders that directly hold
// a note (derived folders, with a null id the caller has already replaced with
// a stable `syn:<path>` id) — plus explicit markers. It omits two things we
// must rebuild here:
//   1. Ancestor folders that hold only sub-folders (no note directly inside).
//   2. Folder dirs that exist only because they hold an attachment.
// And it returns every derived folder unparented (`parent_id: null`), so the
// tree would flatten them all to the root. We therefore re-derive every
// folder's `parent_id` from its path and synthesize any missing ancestor.
// Real folders keep their id; missing nodes get `syn:<full-path>` ids.
export function synthesizeFolders(
  real: Folder[],
  attachments: AttachmentSummary[],
): Folder[] {
  const realByName = new Map<string, Folder>()
  for (const f of real) realByName.set(f.name, f)

  // Every folder path we must represent, plus all of its ancestor prefixes —
  // sourced from both the real folder names and the attachment directories.
  const paths = new Set<string>()
  const addPrefixes = (full: string) => {
    if (!full) return
    const segments = full.split('/')
    for (let i = 1; i <= segments.length; i++) paths.add(segments.slice(0, i).join('/'))
  }
  for (const f of real) addPrefixes(f.name)
  for (const a of attachments) {
    const slash = a.path.lastIndexOf('/')
    if (slash >= 0) addPrefixes(a.path.slice(0, slash))
  }

  // A path's id: the real folder's id when present, else a stable synthetic id.
  // Used for both the node itself and parent links, so they always agree.
  const idFor = (name: string): string => realByName.get(name)?.id ?? syntheticFolderId(name)

  // Emit shallow-first so parents precede children in the output.
  return [...paths]
    .sort((x, y) => x.split('/').length - y.split('/').length)
    .map((name) => {
      const real = realByName.get(name)
      const slash = name.lastIndexOf('/')
      const parentName = slash < 0 ? null : name.slice(0, slash)
      return {
        id: idFor(name),
        parent_id: parentName == null ? null : idFor(parentName),
        name,
        count: real ? real.count : 0,
      }
    })
}
