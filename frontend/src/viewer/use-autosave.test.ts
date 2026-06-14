import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useAutosave } from './use-autosave'

beforeEach(() => vi.useFakeTimers())
afterEach(() => vi.useRealTimers())

describe('useAutosave', () => {
  it('debounces and saves once after the idle window', async () => {
    const save = vi.fn().mockResolvedValue(2)
    const { result } = renderHook(() => useAutosave({ save, version: 1, debounceMs: 800 }))
    act(() => result.current.onEdit('hello'))
    act(() => result.current.onEdit('hello world'))
    expect(save).not.toHaveBeenCalled()
    await act(async () => {
      vi.advanceTimersByTime(800)
    })
    expect(save).toHaveBeenCalledTimes(1)
    expect(save).toHaveBeenCalledWith('hello world', 1)
  })

  it('flush() saves immediately and cancels the pending debounce', async () => {
    const save = vi.fn().mockResolvedValue(2)
    const { result } = renderHook(() => useAutosave({ save, version: 1, debounceMs: 800 }))
    act(() => result.current.onEdit('x'))
    await act(async () => {
      await result.current.flush()
    })
    expect(save).toHaveBeenCalledTimes(1)
    await act(async () => {
      vi.advanceTimersByTime(800)
    })
    expect(save).toHaveBeenCalledTimes(1) // no second save
  })

  it('exposes status: saving -> saved', async () => {
    let resolve!: (v: number) => void
    const save = vi.fn().mockReturnValue(
      new Promise<number>((r) => {
        resolve = r
      }),
    )
    const { result } = renderHook(() => useAutosave({ save, version: 1, debounceMs: 0 }))
    act(() => result.current.onEdit('x'))
    await act(async () => {
      vi.advanceTimersByTime(0)
    })
    expect(result.current.status).toBe('saving')
    await act(async () => {
      resolve(2)
      await Promise.resolve()
    })
    expect(result.current.status).toBe('saved')
  })

  it('sets status=error and stays dirty on save failure', async () => {
    const save = vi.fn().mockRejectedValue(new Error('boom'))
    const { result } = renderHook(() => useAutosave({ save, version: 1, debounceMs: 0 }))
    act(() => result.current.onEdit('x'))
    await act(async () => {
      vi.advanceTimersByTime(0)
      await Promise.resolve()
    })
    expect(result.current.status).toBe('error')
    expect(result.current.dirty).toBe(true)
  })

  it('uses the latest version returned by a prior save', async () => {
    const save = vi.fn().mockResolvedValueOnce(2).mockResolvedValueOnce(3)
    const { result } = renderHook(() => useAutosave({ save, version: 1, debounceMs: 0 }))
    act(() => result.current.onEdit('a'))
    await act(async () => {
      vi.advanceTimersByTime(0)
    })
    act(() => result.current.onEdit('b'))
    await act(async () => {
      vi.advanceTimersByTime(0)
    })
    expect(save).toHaveBeenNthCalledWith(1, 'a', 1)
    expect(save).toHaveBeenNthCalledWith(2, 'b', 2) // version bumped to 2
  })
})
