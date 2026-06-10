import { render } from '@testing-library/react'
import { describe, it, expect } from 'vitest'
import { ConfigProvider } from '@/config-context'
import { useApiUrl, useWsUrl, joinApiUrl, joinWsUrl } from './base'
import type { EngramConfig } from '@/config'

function makeConfig(apiBase: string, wsBase = ''): EngramConfig {
  return {
    authProvider: 'local',
    clerkPublishableKey: '',
    billingEnabled: false,
    clerkWaitlistMode: false,
    apiBase,
    wsBase,
  }
}

function ApiUrlProbe({ path }: { path: string }) {
  const apiUrl = useApiUrl()
  return <span data-testid="out">{apiUrl(path)}</span>
}

function WsUrlProbe({ path }: { path: string }) {
  const wsUrl = useWsUrl()
  return <span data-testid="out">{wsUrl(path)}</span>
}

describe('joinApiUrl (pure)', () => {
  it('selfhost (apiBase=""): leaves /api/notes intact', () => {
    expect(joinApiUrl('', '/api/notes')).toBe('/api/notes')
  })

  it('saas: strips /api prefix and prepends apiBase', () => {
    expect(joinApiUrl('https://api.engram.page', '/api/notes')).toBe('https://api.engram.page/notes')
  })

  it('saas: leaves a non-/api path intact under apiBase', () => {
    expect(joinApiUrl('https://api.engram.page', '/health')).toBe('https://api.engram.page/health')
  })
})

describe('joinWsUrl (pure)', () => {
  it('selfhost (wsBase=""): returns path unchanged', () => {
    expect(joinWsUrl('', '/socket')).toBe('/socket')
  })

  it('saas: prepends wsBase', () => {
    expect(joinWsUrl('wss://api.engram.page', '/socket')).toBe('wss://api.engram.page/socket')
  })
})

describe('useApiUrl', () => {
  it('selfhost (apiBase=""): leaves /api/notes intact', () => {
    const { getByTestId } = render(
      <ConfigProvider config={makeConfig('')}>
        <ApiUrlProbe path="/api/notes" />
      </ConfigProvider>,
    )
    expect(getByTestId('out').textContent).toBe('/api/notes')
  })

  it('saas: strips /api prefix and prepends apiBase', () => {
    const { getByTestId } = render(
      <ConfigProvider config={makeConfig('https://api.engram.page')}>
        <ApiUrlProbe path="/api/notes" />
      </ConfigProvider>,
    )
    expect(getByTestId('out').textContent).toBe('https://api.engram.page/notes')
  })

  it('saas: passes a non-/api path through unchanged after prepending', () => {
    const { getByTestId } = render(
      <ConfigProvider config={makeConfig('https://api.engram.page')}>
        <ApiUrlProbe path="/health" />
      </ConfigProvider>,
    )
    expect(getByTestId('out').textContent).toBe('https://api.engram.page/health')
  })
})

describe('useWsUrl', () => {
  it('selfhost (wsBase=""): returns path unchanged', () => {
    const { getByTestId } = render(
      <ConfigProvider config={makeConfig('', '')}>
        <WsUrlProbe path="/socket" />
      </ConfigProvider>,
    )
    expect(getByTestId('out').textContent).toBe('/socket')
  })

  it('saas: prepends wsBase', () => {
    const { getByTestId } = render(
      <ConfigProvider config={makeConfig('', 'wss://api.engram.page')}>
        <WsUrlProbe path="/socket" />
      </ConfigProvider>,
    )
    expect(getByTestId('out').textContent).toBe('wss://api.engram.page/socket')
  })
})
