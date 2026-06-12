import { renderHook } from '@testing-library/react'
import { act } from 'react'
import { describe, expect, it, vi } from 'vitest'
import { useLongPress } from './use-long-press'

describe('useLongPress', () => {
  it('fires onLongPress after the configured delay', () => {
    vi.useFakeTimers()
    const onLongPress = vi.fn()
    const { result } = renderHook(() => useLongPress({ onLongPress, delayMs: 500 }))
    act(() => result.current.onPointerDown({ pointerId: 1, pointerType: 'touch', clientX: 0, clientY: 0 } as any))
    act(() => vi.advanceTimersByTime(499))
    expect(onLongPress).not.toHaveBeenCalled()
    act(() => vi.advanceTimersByTime(1))
    expect(onLongPress).toHaveBeenCalledOnce()
    vi.useRealTimers()
  })

  it('cancels when pointer moves more than threshold before timer fires', () => {
    vi.useFakeTimers()
    const onLongPress = vi.fn()
    const { result } = renderHook(() => useLongPress({ onLongPress, delayMs: 500, moveThresholdPx: 8 }))
    act(() => result.current.onPointerDown({ pointerId: 1, pointerType: 'touch', clientX: 0, clientY: 0 } as any))
    act(() => result.current.onPointerMove({ pointerId: 1, clientX: 20, clientY: 0 } as any))
    act(() => vi.advanceTimersByTime(600))
    expect(onLongPress).not.toHaveBeenCalled()
    vi.useRealTimers()
  })

  it('cancels on pointerup before timer fires', () => {
    vi.useFakeTimers()
    const onLongPress = vi.fn()
    const { result } = renderHook(() => useLongPress({ onLongPress, delayMs: 500 }))
    act(() => result.current.onPointerDown({ pointerId: 1, pointerType: 'touch', clientX: 0, clientY: 0 } as any))
    act(() => vi.advanceTimersByTime(200))
    act(() => result.current.onPointerUp({ pointerId: 1 } as any))
    act(() => vi.advanceTimersByTime(500))
    expect(onLongPress).not.toHaveBeenCalled()
    vi.useRealTimers()
  })

  it('cleans up timer on unmount', () => {
    vi.useFakeTimers()
    const onLongPress = vi.fn()
    const { result, unmount } = renderHook(() => useLongPress({ onLongPress, delayMs: 500 }))
    act(() => result.current.onPointerDown({ pointerId: 1, pointerType: 'touch', clientX: 0, clientY: 0 } as any))
    unmount()
    act(() => vi.advanceTimersByTime(600))
    expect(onLongPress).not.toHaveBeenCalled()
    vi.useRealTimers()
  })

  it('does NOT fire for a mouse pointer (mouse uses right-click, not long-press)', () => {
    vi.useFakeTimers()
    const onLongPress = vi.fn()
    const { result } = renderHook(() => useLongPress({ onLongPress, delayMs: 500 }))
    act(() =>
      result.current.onPointerDown({
        pointerId: 1,
        pointerType: 'mouse',
        clientX: 0,
        clientY: 0,
      } as any),
    )
    act(() => vi.advanceTimersByTime(600))
    expect(onLongPress).not.toHaveBeenCalled()
    vi.useRealTimers()
  })

  it('fires for a pen pointer (stylus is treated like touch)', () => {
    vi.useFakeTimers()
    const onLongPress = vi.fn()
    const { result } = renderHook(() => useLongPress({ onLongPress, delayMs: 500 }))
    act(() =>
      result.current.onPointerDown({
        pointerId: 1,
        pointerType: 'pen',
        clientX: 0,
        clientY: 0,
      } as any),
    )
    act(() => vi.advanceTimersByTime(500))
    expect(onLongPress).toHaveBeenCalledOnce()
    vi.useRealTimers()
  })

  it('fires onMoveExceedThreshold when threshold exceeded AFTER long-press fires', () => {
    vi.useFakeTimers()
    const onLongPress = vi.fn()
    const onMoveExceedThreshold = vi.fn()
    const { result } = renderHook(() =>
      useLongPress({ onLongPress, onMoveExceedThreshold, delayMs: 500 })
    )
    act(() => result.current.onPointerDown({ pointerId: 1, pointerType: 'touch', clientX: 0, clientY: 0 } as any))
    act(() => vi.advanceTimersByTime(500))
    expect(onLongPress).toHaveBeenCalledOnce()
    act(() => result.current.onPointerMove({ pointerId: 1, clientX: 20, clientY: 0 } as any))
    expect(onMoveExceedThreshold).toHaveBeenCalledOnce()
    vi.useRealTimers()
  })
})
