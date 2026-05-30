import { describe, expect, it } from 'vitest'
import { buildSettingsSections } from './sections'

describe('buildSettingsSections', () => {
  it('prepends Account for clerk auth', () => {
    const sections = buildSettingsSections('clerk', true)
    expect(sections.map((s) => s.to)).toEqual(['account', 'vaults', 'api-keys', 'billing'])
  })

  it('omits Account for local auth', () => {
    const sections = buildSettingsSections('local', true)
    expect(sections.map((s) => s.to)).toEqual(['vaults', 'api-keys', 'billing'])
    expect(sections.some((s) => s.to === 'account')).toBe(false)
  })

  it('omits Billing when billing is disabled (self-host)', () => {
    const sections = buildSettingsSections('local', false)
    expect(sections.map((s) => s.to)).toEqual(['vaults', 'api-keys'])
    expect(sections.some((s) => s.to === 'billing')).toBe(false)
  })

  it('keeps Account but drops Billing for clerk auth with billing disabled', () => {
    const sections = buildSettingsSections('clerk', false)
    expect(sections.map((s) => s.to)).toEqual(['account', 'vaults', 'api-keys'])
  })

  it('includes the Vaults section for clerk + billing', () => {
    const labels = buildSettingsSections('clerk', true).map((s) => s.label)
    expect(labels).toContain('Vaults')
  })

  it('includes the Vaults section for self-host', () => {
    const labels = buildSettingsSections('local', false).map((s) => s.label)
    expect(labels).toContain('Vaults')
  })

  it('appends Administration only for self-host admins', () => {
    expect(buildSettingsSections('local', false, true).map((s) => s.to)).toContain('admin')
    expect(buildSettingsSections('local', false, false).map((s) => s.to)).not.toContain('admin')
    // Clerk never gets the self-host admin section.
    expect(buildSettingsSections('clerk', true, true).map((s) => s.to)).not.toContain('admin')
  })
})
