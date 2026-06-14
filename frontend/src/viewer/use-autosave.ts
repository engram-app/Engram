import { useCallback, useEffect, useRef, useState } from 'react'

export type SaveStatus = 'idle' | 'saving' | 'saved' | 'error'

interface UseAutosaveArgs {
  // Persist content at the given base version; resolve with the NEW version.
  save: (content: string, version: number) => Promise<number>
  version: number
  debounceMs?: number
}

export function useAutosave({ save, version, debounceMs = 800 }: UseAutosaveArgs) {
  const [status, setStatus] = useState<SaveStatus>('idle')
  const [dirty, setDirty] = useState(false)

  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const pending = useRef<string | null>(null) // latest unsaved content
  const versionRef = useRef(version)
  const saveRef = useRef(save)

  useEffect(() => {
    versionRef.current = version
  }, [version])
  useEffect(() => {
    saveRef.current = save
  }, [save])

  const runSave = useCallback(async () => {
    if (pending.current == null) return
    const content = pending.current
    pending.current = null
    setStatus('saving')
    try {
      const next = await saveRef.current(content, versionRef.current)
      versionRef.current = next
      // If new edits arrived during the in-flight save, stay dirty.
      if (pending.current == null) {
        setDirty(false)
        setStatus('saved')
      }
    } catch {
      pending.current = content // requeue for retry/flush
      setDirty(true)
      setStatus('error')
    }
  }, [])

  const onEdit = useCallback(
    (content: string) => {
      pending.current = content
      setDirty(true)
      if (timer.current) clearTimeout(timer.current)
      timer.current = setTimeout(runSave, debounceMs)
    },
    [debounceMs, runSave],
  )

  const flush = useCallback(async () => {
    if (timer.current) {
      clearTimeout(timer.current)
      timer.current = null
    }
    await runSave()
  }, [runSave])

  // Best-effort flush on tab close.
  useEffect(() => {
    const handler = () => {
      void flush()
    }
    window.addEventListener('beforeunload', handler)
    return () => window.removeEventListener('beforeunload', handler)
  }, [flush])

  return { status, dirty, onEdit, flush }
}
