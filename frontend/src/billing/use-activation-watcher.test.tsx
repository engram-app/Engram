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

  it('starts in background after onCheckoutOpened and polls every 10s', async () => {
    get.mockResolvedValue(billingStatus())
    const onActivated = vi.fn()
    const { result } = renderHook(() => useActivationWatcher({ onActivated, enabled: true }), { wrapper })

    expect(get).not.toHaveBeenCalled()
    act(() => { result.current.onCheckoutOpened() })
    expect(result.current.state).toBe('background')

    await act(async () => { await vi.advanceTimersByTimeAsync(10_000) })
    expect(get).toHaveBeenCalledTimes(1)
    await act(async () => { await vi.advanceTimersByTimeAsync(10_000) })
    expect(get).toHaveBeenCalledTimes(2)
    expect(onActivated).not.toHaveBeenCalled()
  })

  it('starts in idle state with no polling until onCheckoutOpened is called', async () => {
    get.mockResolvedValue(billingStatus())
    const onActivated = vi.fn()
    const { result } = renderHook(() => useActivationWatcher({ onActivated, enabled: true }), { wrapper })

    expect(result.current.state).toBe('idle')

    // 60 seconds with no checkout event — zero polls fire.
    await act(async () => { await vi.advanceTimersByTimeAsync(60_000) })
    expect(get).not.toHaveBeenCalled()
    expect(result.current.state).toBe('idle')
  })

  it('transitions idle → background on onCheckoutOpened and starts polling at 10s', async () => {
    get.mockResolvedValue(billingStatus())
    const onActivated = vi.fn()
    const { result } = renderHook(() => useActivationWatcher({ onActivated, enabled: true }), { wrapper })

    act(() => { result.current.onCheckoutOpened() })
    expect(result.current.state).toBe('background')

    await act(async () => { await vi.advanceTimersByTimeAsync(10_000) })
    expect(get).toHaveBeenCalledTimes(1)
  })

  it('onPaymentFailed resets state to idle (not background) so a failed checkout stops polling', async () => {
    get.mockResolvedValue(billingStatus())
    const onActivated = vi.fn()
    const { result } = renderHook(() => useActivationWatcher({ onActivated, enabled: true }), { wrapper })

    act(() => { result.current.onCheckoutOpened() })
    act(() => { result.current.onPaymentInitiated() })
    await act(async () => { await vi.advanceTimersByTimeAsync(1_000) })
    expect(get).toHaveBeenCalledTimes(1)

    act(() => { result.current.onPaymentFailed() })
    expect(result.current.state).toBe('idle')

    // No further polls.
    await act(async () => { await vi.advanceTimersByTimeAsync(30_000) })
    expect(get).toHaveBeenCalledTimes(1)
  })

  it('onCheckoutOpened is idempotent — calling it during accelerated does not regress to background', async () => {
    get.mockResolvedValue(billingStatus())
    const onActivated = vi.fn()
    const { result } = renderHook(() => useActivationWatcher({ onActivated, enabled: true }), { wrapper })

    act(() => { result.current.onCheckoutOpened() })
    act(() => { result.current.onPaymentInitiated() })
    expect(result.current.state).toBe('accelerated')

    act(() => { result.current.onCheckoutOpened() })  // second call — should be no-op
    expect(result.current.state).toBe('accelerated')
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

  it('returns to idle after onPaymentFailed and stops polling', async () => {
    get.mockResolvedValue(billingStatus())
    const onActivated = vi.fn()
    const { result } = renderHook(() => useActivationWatcher({ onActivated, enabled: true }), { wrapper })

    act(() => { result.current.onPaymentInitiated() })
    await act(async () => { await vi.advanceTimersByTimeAsync(1_000) })
    expect(get).toHaveBeenCalledTimes(1)

    act(() => { result.current.onPaymentFailed() })
    expect(result.current.state).toBe('idle')

    // Idle does not poll — even after generous time, count stays at 1.
    await act(async () => { await vi.advanceTimersByTimeAsync(30_000) })
    expect(get).toHaveBeenCalledTimes(1)
  })

  it('does not poll when enabled is false', async () => {
    get.mockResolvedValue(billingStatus())
    renderHook(() => useActivationWatcher({ onActivated: vi.fn(), enabled: false }), { wrapper })
    await act(async () => { await vi.advanceTimersByTimeAsync(60_000) })
    expect(get).not.toHaveBeenCalled()
  })

  it('does not reschedule polls after unmount, even if tick is mid-await', async () => {
    let resolveTick: (v: OnboardingStatus) => void = () => {}
    get.mockImplementation(
      () => new Promise<OnboardingStatus>((r) => { resolveTick = r }),
    )

    const onActivated = vi.fn()
    const { result, unmount } = renderHook(() => useActivationWatcher({ onActivated, enabled: true }), { wrapper })

    // Kick out of idle so polling starts.
    act(() => { result.current.onCheckoutOpened() })

    // Advance to trigger first tick (background = 10s).
    await act(async () => { await vi.advanceTimersByTimeAsync(10_000) })
    expect(get).toHaveBeenCalledTimes(1)

    unmount()

    // Resolve the in-flight api.get AFTER unmount.
    act(() => { resolveTick(billingStatus()) })
    await act(async () => { await Promise.resolve() })

    // Advance plenty more time — no new polls should fire.
    await act(async () => { await vi.advanceTimersByTimeAsync(30_000) })
    expect(get).toHaveBeenCalledTimes(1)
  })

  it('onPaymentInitiated called twice does not extend the 15s accelerated budget', async () => {
    get.mockResolvedValue(billingStatus())
    const onActivated = vi.fn()
    const { result } = renderHook(() => useActivationWatcher({ onActivated, enabled: true }), { wrapper })

    act(() => { result.current.onPaymentInitiated() })
    // 5 seconds in, call again (e.g., CHECKOUT_COMPLETED arrives later).
    await act(async () => { await vi.advanceTimersByTimeAsync(5_000) })
    act(() => { result.current.onPaymentInitiated() })

    // Total budget should still expire at the original 15s mark, not 15s
    // after the second call.
    await act(async () => { await vi.advanceTimersByTimeAsync(10_000) })
    expect(result.current.state).toBe('cooldown')
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
