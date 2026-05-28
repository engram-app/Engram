import { describe, expect, it } from 'vitest'
import { formatMoney } from './format'

describe('formatMoney', () => {
  it('formats two-decimal currencies from minor units', () => {
    expect(formatMoney('2000', 'USD', 'en-US')).toBe('$20.00')
    expect(formatMoney('1234', 'USD', 'en-US')).toBe('$12.34')
  })

  it('formats zero-decimal currencies without dividing', () => {
    // JPY has no minor unit — 2000 minor units is ¥2,000, not ¥20.
    expect(formatMoney('2000', 'JPY', 'en-US')).toBe('¥2,000')
  })

  it('returns null for a missing amount', () => {
    expect(formatMoney(null, 'USD')).toBeNull()
    expect(formatMoney(undefined, 'USD')).toBeNull()
  })

  it('returns null when currency is missing', () => {
    expect(formatMoney('2000', null)).toBeNull()
  })
})
