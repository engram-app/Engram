import {
  useOnboardingStatus,
  useRecordOnboardingAction,
  type OnboardingAction,
} from '../api/queries'

export function useOnboardingActions() {
  const { data, isLoading } = useOnboardingStatus()
  const { mutate, mutateAsync } = useRecordOnboardingAction()

  const actions = new Set<OnboardingAction>(data?.actions ?? [])

  return {
    isLoading,
    vaultCount: data?.vault_count ?? 0,
    has: (a: OnboardingAction) => actions.has(a),
    hasTourDecision:
      actions.has('tour_offered_skipped') || actions.has('tour_completed'),
    record: mutate,
    recordAsync: mutateAsync,
  }
}
