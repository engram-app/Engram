import { describe, it, expect, beforeEach, vi } from 'vitest'
import { loadConfig } from './config'

describe('loadConfig', () => {
  beforeEach(() => {
    delete (window as { __ENGRAM_CONFIG__?: unknown }).__ENGRAM_CONFIG__
    vi.restoreAllMocks()
  })

  it('reads apiBase + wsBase from window injection when present', async () => {
    ;(window as { __ENGRAM_CONFIG__?: unknown }).__ENGRAM_CONFIG__ = {
      authProvider: 'clerk',
      clerkPublishableKey: 'pk_test_x',
      billingEnabled: true,
      clerkWaitlistMode: false,
      apiBase: '',
      wsBase: '',
    }

    const config = await loadConfig()
    expect(config.apiBase).toBe('')
    expect(config.wsBase).toBe('')
    expect(config.authProvider).toBe('clerk')
  })

  it('fetches /config.json when window injection absent', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(
        JSON.stringify({
          authProvider: 'clerk',
          clerkPublishableKey: 'pk_live_x',
          billingEnabled: true,
          clerkWaitlistMode: false,
          apiBase: 'https://api.engram.page',
          wsBase: 'wss://api.engram.page',
        }),
        { status: 200, headers: { 'content-type': 'application/json' } },
      ),
    )

    const config = await loadConfig()
    expect(fetchMock).toHaveBeenCalledWith('/config.json', expect.objectContaining({ cache: 'no-cache' }))
    expect(config.apiBase).toBe('https://api.engram.page')
    expect(config.wsBase).toBe('wss://api.engram.page')
  })

  it('falls back to local defaults when both window + /config.json fail', async () => {
    vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('network'))

    const config = await loadConfig()
    expect(config.authProvider).toBe('local')
    expect(config.apiBase).toBe('')
  })

  it('coerces non-boolean billingEnabled to false from window injection', async () => {
    ;(window as { __ENGRAM_CONFIG__?: unknown }).__ENGRAM_CONFIG__ = {
      authProvider: 'local',
      clerkPublishableKey: '',
      billingEnabled: 'yes',
    }
    const config = await loadConfig()
    expect(config.billingEnabled).toBe(false)
  })

  it('coerces non-boolean clerkWaitlistMode to false from window injection', async () => {
    ;(window as { __ENGRAM_CONFIG__?: unknown }).__ENGRAM_CONFIG__ = {
      authProvider: 'clerk',
      clerkPublishableKey: 'pk_test',
      clerkWaitlistMode: 'yes',
    }
    const config = await loadConfig()
    expect(config.clerkWaitlistMode).toBe(false)
  })

  it('falls back to local provider when window has invalid authProvider', async () => {
    ;(window as { __ENGRAM_CONFIG__?: unknown }).__ENGRAM_CONFIG__ = {
      authProvider: 'rogue',
      clerkPublishableKey: '',
    }
    const config = await loadConfig()
    expect(config.authProvider).toBe('local')
  })
})
