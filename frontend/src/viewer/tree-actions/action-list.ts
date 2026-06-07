export type ActionId = 'rename' | 'move' | 'duplicate' | 'copy-wikilink' | 'delete'

export interface Action {
  id: ActionId
  label: string
  destructive?: boolean
}

const FILE_ACTIONS: Action[] = [
  { id: 'rename', label: 'Rename' },
  { id: 'move', label: 'Move to…' },
  { id: 'duplicate', label: 'Duplicate' },
  { id: 'copy-wikilink', label: 'Copy wikilink' },
  { id: 'delete', label: 'Delete', destructive: true },
]

const FOLDER_ACTIONS: Action[] = [
  { id: 'rename', label: 'Rename' },
  { id: 'move', label: 'Move to…' },
  { id: 'delete', label: 'Delete', destructive: true },
]

export function actionsFor({ kind }: { kind: 'file' | 'folder' }): Action[] {
  return kind === 'file' ? FILE_ACTIONS : FOLDER_ACTIONS
}
