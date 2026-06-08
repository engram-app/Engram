// Shared helpers for deriving a human-readable label from a note path.
// We deliberately avoid using `note.title` (extracted from the first `#`
// heading in markdown) — title doesn't change when a user renames the file,
// so any UI that needs to reflect rename live (folder tree, viewer header,
// dashboard) must label by filename.

const KNOWN_EXTENSIONS = new Set([
  'md',
  'pdf',
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'svg',
  'mp3',
  'mp4',
  'webm',
  'mov',
  'csv',
  'json',
  'txt',
])

export function recognizedExtension(filename: string): string | null {
  const dot = filename.lastIndexOf('.')
  if (dot <= 0) return null
  const ext = filename.slice(dot + 1).toLowerCase()
  return KNOWN_EXTENSIONS.has(ext) ? ext : null
}

// Returns the path's basename minus a recognized extension. For "src/a.md"
// → "a"; for "src/archive.tar.gz" → "archive.tar.gz" (only strip recognized
// extensions so we don't mangle multi-dot filenames into wrong-looking
// pairs).
export function pathLabel(path: string): string {
  const last = path.split('/').pop() ?? path
  const ext = recognizedExtension(last)
  return ext ? last.slice(0, -(ext.length + 1)) : last
}

export function nonMdExtension(path: string): string | null {
  const last = path.split('/').pop() ?? path
  const ext = recognizedExtension(last)
  return ext && ext !== 'md' ? ext : null
}
