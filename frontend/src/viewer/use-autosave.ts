import { useCallback, useEffect, useRef, useState } from 'react'

export type SaveStatus = 'idle' | 'saving' | 'saved' | 'error'

interface UseAutosaveArgs {
  // Persist content at the given base version; resolve with the NEW version.
  save: (content: string, version: number) => Promise<number>
  version: number
  // Identity of the note being edited. A change resets the tracked version to
  // `version` (a different note has its own version line); within one note the
  // version only advances, so a stale refetch can't regress it under a save.
  noteId: string | null
  onError?: (err: unknown) => void
  debounceMs?: number
}

export function useAutosave({ save, version, noteId, onError, debounceMs = 800 }: UseAutosaveArgs) {
  const [status, setStatus] = useState<SaveStatus>('idle')
  const [dirty, setDirty] = useState(false)

  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const pending = useRef<string | null>(null) // latest unsaved content
  const versionRef = useRef(version)
  const lastNoteId = useRef(noteId)
  const saveRef = useRef(save)
  const onErrorRef = useRef(onError)

  useEffect(() => {
    // Reset on note switch; otherwise only move forward — never clobber a
    // version a just-completed save advanced past the (lagging) prop.
    if (noteId !== lastNoteId.current) {
      lastNoteId.current = noteId
      versionRef.current = version
    } else if (version > versionRef.current) {
      versionRef.current = version
    }
  }, [noteId, version])
  useEffect(() => {
    saveRef.current = save
  }, [save])
  useEffect(() => {
    onErrorRef.current = onError
  }, [onError])

  // Explicitly advance the tracked version — e.g. after a remote merge applied
  // a newer server revision, so the next save bases off it instead of 409ing.
  const setVersion = useCallback((v: number) => {
    if (v > versionRef.current) versionRef.current = v
  }, [])

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
    } catch (err) {
      pending.current = content // requeue for retry/flush
      setDirty(true)
      setStatus('error')
      onErrorRef.current?.(err)
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

  return { status, dirty, onEdit, flush, setVersion, retry: flush }
}
