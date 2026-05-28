import { describe, expect, it } from 'vitest'
import { buildSettingsSections } from './sections'

describe('buildSettingsSections', () => {
  it('prepends Account for clerk auth', () => {
    const sections = buildSettingsSections('clerk')
    expect(sections.map((s) => s.to)).toEqual(['account', 'api-keys', 'billing'])
  })

  it('omits Account for local auth', () => {
    const sections = buildSettingsSections('local')
    expect(sections.map((s) => s.to)).toEqual(['api-keys', 'billing'])
    expect(sections.some((s) => s.to === 'account')).toBe(false)
  })
})
