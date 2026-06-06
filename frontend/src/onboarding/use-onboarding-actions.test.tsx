import { describe, expect, it, vi } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { useOnboardingActions } from './use-onboarding-actions'

vi.mock('../api/queries', () => ({
  useOnboardingStatus: () => ({
    data: {
      enabled: true,
      next_step: 'done',
      actions: ['first_vault_created'],
      vault_count: 1,
    },
    isLoading: false,
  }),
  useRecordOnboardingAction: () => ({ mutate: vi.fn(), mutateAsync: vi.fn() }),
}))

const wrap = ({ children }: { children: React.ReactNode }) => (
  <QueryClientProvider client={new QueryClient()}>{children}</QueryClientProvider>
)

describe('useOnboardingActions', () => {
  it('has + derived flags reflect actions list', () => {
    const { result } = renderHook(() => useOnboardingActions(), { wrapper: wrap })
    expect(result.current.has('first_vault_created')).toBe(true)
    expect(result.current.has('plugin_connected')).toBe(false)
    expect(result.current.vaultCount).toBe(1)
  })
})
