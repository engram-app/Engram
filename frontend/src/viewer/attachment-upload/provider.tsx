import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react'
import { useFolders } from '@/api/queries'
import { AttachmentUploadDialog } from './upload-dialog'

interface UploadApi {
  openUpload: (files?: File[]) => void
}

const Ctx = createContext<UploadApi | null>(null)

export function useAttachmentUpload(): UploadApi {
  const v = useContext(Ctx)
  if (!v) throw new Error('useAttachmentUpload must be used within AttachmentUploadProvider')
  return v
}

function hasFiles(e: DragEvent): boolean {
  return Array.from(e.dataTransfer?.types ?? []).includes('Files')
}

export function AttachmentUploadProvider({ children }: { children: React.ReactNode }) {
  const [files, setFiles] = useState<File[] | null>(null) // null = dialog closed
  const [dragging, setDragging] = useState(false)
  const depth = useRef(0)
  const pickerRef = useRef<HTMLInputElement>(null)
  const folders = useFolders().data ?? []

  // No files → open the OS picker (the dialog opens once files are chosen, so
  // the button never flashes an empty dialog). Files present → open directly.
  const openUpload = useCallback((dropped?: File[]) => {
    if (dropped && dropped.length > 0) setFiles(dropped)
    else pickerRef.current?.click()
  }, [])

  // Window-level drag handling. The hasFiles() guard means INTERNAL headless-tree
  // note/folder drags (which carry no 'Files' type) never trip the overlay — the
  // single most important invariant of this feature.
  useEffect(() => {
    const onEnter = (e: DragEvent) => {
      if (!hasFiles(e)) return
      e.preventDefault()
      depth.current += 1
      setDragging(true)
    }
    const onOver = (e: DragEvent) => {
      if (!hasFiles(e)) return
      e.preventDefault() // required so 'drop' fires
    }
    const onLeave = (e: DragEvent) => {
      if (!hasFiles(e)) return
      depth.current -= 1
      if (depth.current <= 0) {
        depth.current = 0
        setDragging(false)
      }
    }
    const onDrop = (e: DragEvent) => {
      if (!hasFiles(e)) return
      e.preventDefault()
      depth.current = 0
      setDragging(false)
      const dropped = Array.from(e.dataTransfer?.files ?? [])
      if (dropped.length > 0) setFiles(dropped)
    }
    window.addEventListener('dragenter', onEnter)
    window.addEventListener('dragover', onOver)
    window.addEventListener('dragleave', onLeave)
    window.addEventListener('drop', onDrop)
    return () => {
      window.removeEventListener('dragenter', onEnter)
      window.removeEventListener('dragover', onOver)
      window.removeEventListener('dragleave', onLeave)
      window.removeEventListener('drop', onDrop)
    }
  }, [])

  return (
    <Ctx.Provider value={{ openUpload }}>
      {children}
      <input
        ref={pickerRef}
        type="file"
        multiple
        hidden
        onChange={(e) => {
          const picked = Array.from(e.target.files ?? [])
          e.target.value = ''
          if (picked.length > 0) setFiles(picked)
        }}
      />
      {dragging && (
        <div
          aria-hidden
          className="fixed inset-0 z-50 flex items-center justify-center bg-blue-500/10 ring-2 ring-inset ring-blue-400 backdrop-blur-sm"
        >
          <p className="rounded-lg bg-card px-6 py-4 text-lg font-medium shadow-xl">Drop files to upload</p>
        </div>
      )}
      {files !== null && (
        <AttachmentUploadDialog
          initialFiles={files}
          folders={folders.map((f) => ({ name: f.name }))}
          onClose={() => setFiles(null)}
        />
      )}
    </Ctx.Provider>
  )
}
