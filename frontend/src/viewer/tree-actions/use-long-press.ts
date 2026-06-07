import type React from 'react'
import { useCallback, useEffect, useRef } from 'react'

interface Options {
  onLongPress: () => void
  onMoveExceedThreshold?: () => void
  delayMs?: number
  moveThresholdPx?: number
}

export function useLongPress({
  onLongPress,
  onMoveExceedThreshold,
  delayMs = 500,
  moveThresholdPx = 8,
}: Options) {
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const start = useRef<{ x: number; y: number } | null>(null)
  const fired = useRef(false)

  const cancel = useCallback(() => {
    if (timer.current) {
      clearTimeout(timer.current)
      timer.current = null
    }
    start.current = null
    fired.current = false
  }, [])

  useEffect(() => cancel, [cancel])

  return {
    onPointerDown(e: React.PointerEvent) {
      cancel()
      start.current = { x: e.clientX, y: e.clientY }
      timer.current = setTimeout(() => {
        fired.current = true
        onLongPress()
      }, delayMs)
    },
    onPointerMove(e: React.PointerEvent) {
      if (!start.current) return
      const dx = e.clientX - start.current.x
      const dy = e.clientY - start.current.y
      if (dx * dx + dy * dy > moveThresholdPx * moveThresholdPx) {
        if (fired.current) {
          onMoveExceedThreshold?.()
        }
        cancel()
      }
    },
    onPointerUp(_e: React.PointerEvent) {
      cancel()
    },
    onPointerCancel(_e: React.PointerEvent) {
      cancel()
    },
  }
}
