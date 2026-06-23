import { describe, expect, it } from 'vitest'
import { signInRedirectTarget } from './sign-in-redirect'

describe('signInRedirectTarget', () => {
  it('redirects to bare sign-in from the home path (no return_to round-trip)', () => {
    expect(signInRedirectTarget({ pathname: '/', search: '', hash: '' })).toBe('/sign-in')
  })

  it('preserves the original path as an encoded return_to', () => {
    expect(signInRedirectTarget({ pathname: '/note/abc', search: '', hash: '' })).toBe(
      '/sign-in?return_to=%2Fnote%2Fabc',
    )
  })

  it('includes search and hash in the return_to', () => {
    expect(
      signInRedirectTarget({ pathname: '/settings', search: '?tab=billing', hash: '#plan' }),
    ).toBe('/sign-in?return_to=%2Fsettings%3Ftab%3Dbilling%23plan')
  })
})
