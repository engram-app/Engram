import { useState } from 'react'
import { useNavigate } from 'react-router'
import { useAcceptTerms, useOnboardingStatus } from '../api/queries'
import { loadVersion, sha256Hex } from '../legal/load'
import { LegalDoc } from '../legal/legal-doc'
import { Checkbox } from '@/components/ui/checkbox'
import { cn } from '@/lib/utils'

const PRIVACY_URL = 'https://engram.page/privacy'

export default function AgreementPage() {
  const [agreed, setAgreed] = useState(false)
  const navigate = useNavigate()
  const { data } = useOnboardingStatus()
  const { mutateAsync, isPending } = useAcceptTerms()

  const tosV = data?.current_tos_version
  const privV = data?.current_privacy_version

  // loadVersion throws if a canonical version isn't bundled — this is the
  // intended runtime assert: the app must never let someone accept text it
  // cannot display in full. The error surfaces to the nearest error boundary
  // rather than silently rendering an empty agreement.
  const tosText = tosV ? loadVersion('terms', tosV) : undefined
  const privText = privV ? loadVersion('privacy', privV) : undefined

  const ready = Boolean(tosV && privV && tosText && privText)

  async function submit() {
    if (!tosV || !privV || !tosText || !privText) return
    const [tos_hash, privacy_hash] = await Promise.all([
      sha256Hex(tosText),
      sha256Hex(privText),
    ])
    await mutateAsync({
      tos_version: tosV,
      tos_hash,
      privacy_version: privV,
      privacy_hash,
    })
    navigate('/onboard', { replace: true })
  }

  return (
    <section className="m-auto w-full max-w-2xl px-4 py-6">
      <div className="flex flex-col gap-4 rounded-2xl border border-border bg-background p-5 sm:p-6">
        <h1 className="text-2xl font-bold tracking-tight text-foreground sm:text-3xl">
          Review the Terms
        </h1>
        <p className="text-sm text-muted-foreground">
          Please read the full agreement below before continuing. Our{' '}
          <a
            href={PRIVACY_URL}
            target="_blank"
            rel="noreferrer noopener"
            className="font-medium text-primary underline-offset-4 hover:underline"
          >
            privacy notice
          </a>{' '}
          (reviewed at signup) describes how we handle your data.
        </p>
        {tosText ? (
          <div className="max-h-96 overflow-y-auto rounded-lg border border-border bg-background p-4">
            <LegalDoc source={tosText} />
          </div>
        ) : null}
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
            I have read and agree to the agreement shown above and the privacy notice
          </span>
        </label>
        <button
          type="button"
          onClick={submit}
          disabled={!agreed || isPending || !ready}
          className="w-full rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition hover:bg-primary/90 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {isPending ? 'Saving…' : 'Continue'}
        </button>
      </div>
    </section>
  )
}
