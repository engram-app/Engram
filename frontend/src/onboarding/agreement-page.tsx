import { useState } from 'react'
import { useNavigate } from 'react-router'
import { useAcceptTerms, useOnboardingStatus } from '../api/queries'
import { TERMS_VERSION } from '../legal/terms-of-service'
import { Checkbox } from '@/components/ui/checkbox'
import { cn } from '@/lib/utils'

const TERMS_URL = 'https://engram.page/terms'
const PRIVACY_URL = 'https://engram.page/privacy'

export default function AgreementPage() {
  const [agreed, setAgreed] = useState(false)
  const navigate = useNavigate()
  const { data } = useOnboardingStatus()
  const { mutateAsync, isPending } = useAcceptTerms()

  const version = data?.current_tos_version ?? TERMS_VERSION

  async function submit() {
    await mutateAsync(version)
    navigate('/onboard', { replace: true })
  }

  return (
    <section className="m-auto w-full max-w-2xl px-4 py-6">
      <div className="flex flex-col gap-4 rounded-2xl border border-border bg-background p-5 sm:p-6">
        <h1 className="text-2xl font-bold tracking-tight text-foreground sm:text-3xl">
          Review the Terms
        </h1>
        <p className="text-sm text-muted-foreground">
          Before you continue, please read our{' '}
          <a
            href={TERMS_URL}
            target="_blank"
            rel="noreferrer noopener"
            className="font-medium text-primary underline-offset-4 hover:underline"
          >
            Terms of Service
          </a>{' '}
          and{' '}
          <a
            href={PRIVACY_URL}
            target="_blank"
            rel="noreferrer noopener"
            className="font-medium text-primary underline-offset-4 hover:underline"
          >
            Privacy Policy
          </a>
          . They open in a new tab.
        </p>
        <label
          className={cn(
            'flex cursor-pointer items-center gap-3 rounded-lg border p-4 transition-colors',
            agreed ? 'border-primary bg-primary/5' : 'border-border hover:border-primary/50',
          )}
        >
          <Checkbox
            checked={agreed}
            onCheckedChange={(v) => setAgreed(v === true)}
            aria-label="I have read and agree to the Terms of Service and Privacy Policy"
          />
          <span className="text-sm font-medium text-foreground">
            I have read and agree to the Terms of Service and Privacy Policy
          </span>
        </label>
        <button
          type="button"
          onClick={submit}
          disabled={!agreed || isPending}
          className="w-full rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {isPending ? 'Saving…' : 'Continue'}
        </button>
      </div>
    </section>
  )
}
