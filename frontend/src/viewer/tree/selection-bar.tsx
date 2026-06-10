interface Props {
  count: number
  onMove: () => void
  onDelete: () => void
  onCancel: () => void
}

export function SelectionBar({ count, onMove, onDelete, onCancel }: Props) {
  if (count === 0) return null
  return (
    <div
      role="toolbar"
      aria-label="Selection actions"
      className="sticky bottom-0 z-10 flex items-center justify-between gap-2 border-t border-gray-300 bg-white p-2 dark:border-gray-700 dark:bg-gray-900"
    >
      <span className="text-sm text-gray-600 dark:text-gray-400">{count} selected</span>
      <div className="flex gap-2">
        <button
          type="button"
          onClick={onMove}
          className="rounded bg-blue-600 px-3 py-1 text-sm text-white hover:bg-blue-700"
        >
          Move {count}
        </button>
        <button
          type="button"
          onClick={onDelete}
          className="rounded bg-red-600 px-3 py-1 text-sm text-white hover:bg-red-700"
        >
          Delete {count}
        </button>
        <button
          type="button"
          onClick={onCancel}
          className="rounded border border-gray-300 px-3 py-1 text-sm dark:border-gray-700"
        >
          Cancel
        </button>
      </div>
    </div>
  )
}
