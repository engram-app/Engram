import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import React from 'react'
import { AuthContext, type AuthAdapter } from '../auth/auth-context'

const {
  channelHandlers,
  channelOn,
  socketChannelMock,
  socketConnectMock,
  socketDisconnectMock,
  socketCtor,
} = vi.hoisted(() => {
  const channelHandlers: Record<string, (payload: unknown) => void> = {}
  const channelOn = vi.fn((event: string, cb: (payload: unknown) => void) => {
    channelHandlers[event] = cb
  })
  const channelMock = {
    on: channelOn,
    join: () => ({ receive: () => ({}) }),
  }
  const socketChannelMock = vi.fn(() => channelMock)
  const socketConnectMock = vi.fn()
  const socketDisconnectMock = vi.fn()
  // Phoenix's Socket is invoked with `new` — use a constructor function (not a
  // vi.fn() arrow returning an object, which Mock's `new` semantics reject).
  const socketCtor = vi.fn(function MockSocket(this: object, ..._args: unknown[]) {
    Object.assign(this, {
      connect: socketConnectMock,
      channel: socketChannelMock,
      disconnect: socketDisconnectMock,
    })
  })
  return {
    channelHandlers,
    channelOn,
    socketChannelMock,
    socketConnectMock,
    socketDisconnectMock,
    socketCtor,
  }
})

vi.mock('phoenix', () => ({ Socket: socketCtor }))

import { useSubscriptionActivatedEvents } from './use-subscription-activated-events'

const authAdapter: AuthAdapter = {
  isLoaded: true,
  isSignedIn: true,
  user: { email: 'u@example.com' },
  getToken: async () => 'tok-test',
  logout: async () => {},
  hasBuiltInUI: false,
}

function wrap({ children }: { children: React.ReactNode }) {
  return React.createElement(AuthContext.Provider, { value: authAdapter }, children)
}

describe('useSubscriptionActivatedEvents', () => {
  beforeEach(() => {
    socketCtor.mockClear()
    socketChannelMock.mockClear()
    socketConnectMock.mockClear()
    socketDisconnectMock.mockClear()
    channelOn.mockClear()
    for (const k of Object.keys(channelHandlers)) delete channelHandlers[k]
  })

  it('connects to user:{userId} and subscribes to subscription_activated', async () => {
    const onActivated = vi.fn()
    renderHook(
      () => useSubscriptionActivatedEvents({ userId: 42, enabled: true, onActivated }),
      { wrapper: wrap },
    )
    await act(async () => {
      await Promise.resolve()
      await Promise.resolve()
    })
    expect(socketCtor).toHaveBeenCalledWith('/socket', { params: { token: 'tok-test' } })
    expect(socketChannelMock).toHaveBeenCalledWith('user:42')
    expect(channelHandlers['subscription_activated']).toBeDefined()
  })

  it('invokes onActivated when the channel fires subscription_activated', async () => {
    const onActivated = vi.fn()
    renderHook(
      () => useSubscriptionActivatedEvents({ userId: 42, enabled: true, onActivated }),
      { wrapper: wrap },
    )
    await act(async () => {
      await Promise.resolve()
      await Promise.resolve()
    })

    act(() => {
      channelHandlers['subscription_activated']!({
        tier: 'starter',
        status: 'trialing',
        subscription_id: 'sub_1',
      })
    })

    expect(onActivated).toHaveBeenCalledWith({
      tier: 'starter',
      status: 'trialing',
      subscription_id: 'sub_1',
    })
  })

  it('does not connect when enabled is false', async () => {
    renderHook(
      () =>
        useSubscriptionActivatedEvents({
          userId: 42,
          enabled: false,
          onActivated: vi.fn(),
        }),
      { wrapper: wrap },
    )
    await act(async () => {
      await Promise.resolve()
    })
    expect(socketCtor).not.toHaveBeenCalled()
  })

  it('does not connect when userId is null', async () => {
    renderHook(
      () =>
        useSubscriptionActivatedEvents({
          userId: null,
          enabled: true,
          onActivated: vi.fn(),
        }),
      { wrapper: wrap },
    )
    await act(async () => {
      await Promise.resolve()
    })
    expect(socketCtor).not.toHaveBeenCalled()
  })

  it('disconnects the socket on unmount', async () => {
    const { unmount } = renderHook(
      () =>
        useSubscriptionActivatedEvents({
          userId: 42,
          enabled: true,
          onActivated: vi.fn(),
        }),
      { wrapper: wrap },
    )
    await act(async () => {
      await Promise.resolve()
      await Promise.resolve()
    })
    unmount()
    expect(socketDisconnectMock).toHaveBeenCalledOnce()
  })
})
