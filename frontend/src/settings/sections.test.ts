import { describe, expect, it } from 'vitest'
import { buildSettingsSections } from './sections'

describe('buildSettingsSections', () => {
  it('prepends Account for clerk auth', () => {
    const sections = buildSettingsSections('clerk')
    expect(sections.map((s) => s.to)).toEqual([
      'account',
      'appearance',
      'api-keys',
      'encryption',
      'billing',
    ])
  })

  it('omits Account for local auth', () => {
    const sections = buildSettingsSections('local')
    expect(sections.map((s) => s.to)).toEqual([
      'appearance',
      'api-keys',
      'encryption',
      'billing',
    ])
    expect(sections.some((s) => s.to === 'account')).toBe(false)
  })
})
