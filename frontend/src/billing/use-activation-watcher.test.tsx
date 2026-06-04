import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import React from 'react'
import { useActivationWatcher } from './use-activation-watcher'
import type { OnboardingStatus } from '../api/queries'

const { get } = vi.hoisted(() => ({ get: vi.fn() }))
vi.mock('../api/client', () => ({
  api: { get, post: vi.fn(), patch: vi.fn(), del: vi.fn() },
  setTokenGetter: vi.fn(),
}))

function billingStatus(): OnboardingStatus {
  return {
    enabled: true,
    next_step: 'billing',
    subscription_ok: false,
    terms_ok: true,
    steps: ['agreement', 'billing', 'tools', 'vault'],
    actions: [],
    vault_count: 0,
  } as unknown as OnboardingStatus
}

function activeStatus(next: 'tools' | 'done' = 'tools'): OnboardingStatus {
  return {
    ...billingStatus(),
    next_step: next,
    subscription_ok: true,
  } as unknown as OnboardingStatus
}

function wrapper({ children }: { children: React.ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

describe('useActivationWatcher', () => {
  beforeEach(() => {
    get.mockReset()
    vi.useFakeTimers({ shouldAdvanceTime: true })
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('starts in background state and polls every 10s', async () => {
    get.mockResolvedValue(billingStatus())
    const onActivated = vi.fn()
    renderHook(() => useActivationWatcher({ onActivated, enabled: true }), { wrapper })

    expect(get).not.toHaveBeenCalled()
    await act(async () => { await vi.advanceTimersByTimeAsync(10_000) })
    expect(get).toHaveBeenCalledTimes(1)
    await act(async () => { await vi.advanceTimersByTimeAsync(10_000) })
    expect(get).toHaveBeenCalledTimes(2)
    expect(onActivated).not.toHaveBeenCalled()
  })

  it('accelerates to 1s after onPaymentInitiated', async () => {
    get.mockResolvedValue(billingStatus())
    const onActivated = vi.fn()
    const { result } = renderHook(() => useActivationWatcher({ onActivated, enabled: true }), { wrapper })

    act(() => { result.current.onPaymentInitiated() })

    await act(async () => { await vi.advanceTimersByTimeAsync(1_000) })
    expect(get).toHaveBeenCalledTimes(1)
    await act(async () => { await vi.advanceTimersByTimeAsync(1_000) })
    expect(get).toHaveBeenCalledTimes(2)
    expect(result.current.state).toBe('accelerated')
  })

  it('fires onActivated exactly once when poll sees next_step !== billing', async () => {
    let count = 0
    get.mockImplementation(async () => (count++ === 0 ? billingStatus() : activeStatus('tools')))
    const onActivated = vi.fn()
    const { result } = renderHook(() => useActivationWatcher({ onActivated, enabled: true }), { wrapper })

    act(() => { result.current.onPaymentInitiated() })
    await act(async () => { await vi.advanceTimersByTimeAsync(1_000) })
    await act(async () => { await vi.advanceTimersByTimeAsync(1_000) })
    await act(async () => { await vi.advanceTimersByTimeAsync(5_000) })

    expect(onActivated).toHaveBeenCalledTimes(1)
    expect(onActivated).toHaveBeenCalledWith(expect.objectContaining({ next_step: 'tools' }))
    expect(result.current.state).toBe('activated')
  })

  it('enters cooldown at 15s and continues polling at 5s', async () => {
    get.mockResolvedValue(billingStatus())
    const onActivated = vi.fn()
    const { result } = renderHook(() => useActivationWatcher({ onActivated, enabled: true }), { wrapper })

    act(() => { result.current.onPaymentInitiated() })
    await act(async () => { await vi.advanceTimersByTimeAsync(15_000) })
    expect(get).toHaveBeenCalledTimes(15)
    expect(result.current.state).toBe('cooldown')

    // Next call should be at 5s after entering cooldown.
    await act(async () => { await vi.advanceTimersByTimeAsync(1_000) })
    expect(get).toHaveBeenCalledTimes(15)
    await act(async () => { await vi.advanceTimersByTimeAsync(4_000) })
    expect(get).toHaveBeenCalledTimes(16)
  })

  it('returns to background after onPaymentFailed', async () => {
    get.mockResolvedValue(billingStatus())
    const onActivated = vi.fn()
    const { result } = renderHook(() => useActivationWatcher({ onActivated, enabled: true }), { wrapper })

    act(() => { result.current.onPaymentInitiated() })
    await act(async () => { await vi.advanceTimersByTimeAsync(1_000) })
    expect(get).toHaveBeenCalledTimes(1)

    act(() => { result.current.onPaymentFailed() })
    expect(result.current.state).toBe('background')

    await act(async () => { await vi.advanceTimersByTimeAsync(5_000) })
    expect(get).toHaveBeenCalledTimes(1)
    await act(async () => { await vi.advanceTimersByTimeAsync(5_000) })
    expect(get).toHaveBeenCalledTimes(2)
  })

  it('does not poll when enabled is false', async () => {
    get.mockResolvedValue(billingStatus())
    renderHook(() => useActivationWatcher({ onActivated: vi.fn(), enabled: false }), { wrapper })
    await act(async () => { await vi.advanceTimersByTimeAsync(60_000) })
    expect(get).not.toHaveBeenCalled()
  })

  it('survives a transient poll error without crashing', async () => {
    get
      .mockRejectedValueOnce(new Error('boom'))
      .mockResolvedValue(activeStatus('tools'))
    const onActivated = vi.fn()
    const { result } = renderHook(() => useActivationWatcher({ onActivated, enabled: true }), { wrapper })

    act(() => { result.current.onPaymentInitiated() })
    await act(async () => { await vi.advanceTimersByTimeAsync(1_000) })
    expect(result.current.state).toBe('accelerated')
    await act(async () => { await vi.advanceTimersByTimeAsync(1_000) })
    expect(onActivated).toHaveBeenCalledTimes(1)
  })
})
