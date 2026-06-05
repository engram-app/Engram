import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'

export type OverlayState = 'accelerated' | 'cooldown' | 'activated'

type StepState = 'pending' | 'active' | 'done'

interface Props {
  state: OverlayState
  subscriptionOk: boolean
  nextStep: string
  transactionId: string | null
  onRefresh: () => void
  onContactSupport: () => void
}

export function ActivationOverlay({
  state,
  subscriptionOk,
  nextStep,
  transactionId,
  onRefresh,
  onContactSupport,
}: Props) {
  // Step 1: Paddle confirmed payment client-side. We render only when triggered
  // by CHECKOUT_PAYMENT_INITIATED, so step 1 is always done by definition.
  const step1: StepState = 'done'

  // Step 2: backend confirms subscription_ok (the webhook landed).
  const step2: StepState = state === 'activated' || subscriptionOk ? 'done' : 'active'

  // Step 3: the full onboarding gate has cleared — next_step is no longer
  // 'billing'. For first-time signups step 2 and 3 typically tick in the
  // same poll, but they're independent backend signals (subscription vs.
  // full gate).
  const step3: StepState =
    state === 'activated' || nextStep !== 'billing'
      ? 'done'
      : subscriptionOk
        ? 'active'
        : 'pending'

  const cooldown = state === 'cooldown'

  return (
    <section
      className="absolute inset-0 z-10 flex items-center justify-center bg-background/80 backdrop-blur-sm"
      aria-live="polite"
    >
      <div className="w-full max-w-md rounded-2xl border border-border bg-card p-6 shadow-lg">
        <header className="mb-4">
          <h2 className="text-lg font-semibold text-foreground">Activating your subscription</h2>
        </header>

        <ol className="space-y-3">
          <Step n={1} label="Payment received" state={step1} />
          <Step
            n={2}
            label="Activating subscription"
            state={step2}
            warning={cooldown && step2 !== 'done'}
          />
          <Step n={3} label="Preparing your account" state={step3} />
        </ol>

        {cooldown ? (
          <div role="alert" className="mt-5 rounded-lg border border-border bg-muted p-4 text-sm">
            <p className="font-medium text-foreground">
              Payment confirmed. Activation is taking a bit longer than usual.
            </p>
            <p className="mt-1 text-muted-foreground">
              We'll auto-continue when it's ready — or you can refresh.
            </p>
            <div className="mt-3 flex flex-wrap gap-2">
              <Button size="sm" onClick={onRefresh}>Refresh</Button>
              <Button size="sm" variant="outline" onClick={onContactSupport}>Contact support</Button>
            </div>
            {transactionId ? (
              <p className="mt-3 text-xs text-muted-foreground">Reference: {transactionId}</p>
            ) : null}
          </div>
        ) : (
          <p role="status" className="mt-4 text-sm text-muted-foreground">
            {state === 'activated' ? "Done — taking you in." : 'Activating your subscription…'}
          </p>
        )}
      </div>
    </section>
  )
}

interface StepProps {
  n: number
  label: string
  state: StepState
  warning?: boolean
}

function Step({ n, label, state, warning = false }: StepProps) {
  return (
    <li className="flex items-center gap-3" data-testid={`step-${n}`} data-state={state}>
      <span
        className={cn(
          'flex h-6 w-6 items-center justify-center rounded-full text-xs font-semibold',
          state === 'done' && 'bg-primary text-primary-foreground',
          state === 'active' && !warning && 'animate-pulse bg-primary/30 text-foreground',
          state === 'active' && warning && 'animate-pulse bg-amber-400/30 text-amber-700 dark:text-amber-300',
          state === 'pending' && 'bg-muted text-muted-foreground',
        )}
        aria-hidden="true"
      >
        {state === 'done' ? '✓' : n}
      </span>
      <span className={cn('text-sm', state === 'done' ? 'text-foreground' : 'text-muted-foreground')}>
        {label}
      </span>
    </li>
  )
}
