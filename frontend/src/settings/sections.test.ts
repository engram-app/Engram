import { describe, expect, it } from 'vitest'
import { buildSettingsSections } from './sections'

describe('buildSettingsSections', () => {
  it('includes Account first for local auth', () => {
    const sections = buildSettingsSections('local', false, false)
    expect(sections[0]).toEqual({ to: 'account', label: 'Account' })
    expect(sections.map((s) => s.to)).toContain('vaults')
    expect(sections.map((s) => s.to)).toContain('api-keys')
  })

  it('includes Account first for clerk', () => {
    const sections = buildSettingsSections('clerk', true, false)
    expect(sections[0]).toEqual({ to: 'account', label: 'Account' })
    expect(sections.map((s) => s.to)).toContain('billing')
  })

  it('appends Administration for local admins', () => {
    const sections = buildSettingsSections('local', false, true)
    expect(sections.map((s) => s.to)).toContain('admin')
  })

  it('does not include Administration for clerk', () => {
    const sections = buildSettingsSections('clerk', true, true)
    expect(sections.map((s) => s.to)).not.toContain('admin')
  })
})
