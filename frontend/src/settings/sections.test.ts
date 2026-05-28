import { describe, expect, it } from 'vitest'
import { buildSettingsSections } from './sections'

describe('buildSettingsSections', () => {
  it('prepends Account for clerk auth', () => {
    const sections = buildSettingsSections('clerk', true)
    expect(sections.map((s) => s.to)).toEqual(['account', 'api-keys', 'billing'])
  })

  it('omits Account for local auth', () => {
    const sections = buildSettingsSections('local', true)
    expect(sections.map((s) => s.to)).toEqual(['api-keys', 'billing'])
    expect(sections.some((s) => s.to === 'account')).toBe(false)
  })

  it('omits Billing when billing is disabled (self-host)', () => {
    const sections = buildSettingsSections('local', false)
    expect(sections.map((s) => s.to)).toEqual(['api-keys'])
    expect(sections.some((s) => s.to === 'billing')).toBe(false)
  })

  it('keeps Account but drops Billing for clerk auth with billing disabled', () => {
    const sections = buildSettingsSections('clerk', false)
    expect(sections.map((s) => s.to)).toEqual(['account', 'api-keys'])
  })
})
