import { afterEach, describe, expect, it } from 'vitest'
import { loadConfig } from './config'

type InjectedConfig = Record<string, unknown>

function inject(value: InjectedConfig | undefined) {
  ;(window as unknown as { __ENGRAM_CONFIG__?: InjectedConfig }).__ENGRAM_CONFIG__ = value
}

describe('loadConfig', () => {
  afterEach(() => {
    inject(undefined)
  })

  it('reads billingEnabled=true from injected config', () => {
    inject({ authProvider: 'clerk', clerkPublishableKey: 'pk_test', billingEnabled: true })
    expect(loadConfig().billingEnabled).toBe(true)
  })

  it('treats a missing billingEnabled as false', () => {
    inject({ authProvider: 'clerk', clerkPublishableKey: 'pk_test' })
    expect(loadConfig().billingEnabled).toBe(false)
  })

  it('coerces non-boolean billingEnabled to false (never truthy-by-accident)', () => {
    inject({ authProvider: 'local', clerkPublishableKey: '', billingEnabled: 'yes' })
    expect(loadConfig().billingEnabled).toBe(false)
  })
})
