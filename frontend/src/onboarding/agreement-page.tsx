import { useState } from 'react'
import { useAcceptTerms, useOnboardingStatus } from '../api/queries'
import { TERMS_VERSION, TermsContent } from '../legal/terms-of-service'

export default function AgreementPage() {
  const [agreed, setAgreed] = useState(false)
  const { data } = useOnboardingStatus()
  const { mutateAsync, isPending } = useAcceptTerms()

  const version = data?.current_tos_version ?? TERMS_VERSION

  async function submit() {
    await mutateAsync(version)
  }

  return (
    <section className="agreement-page">
      <article className="prose">
        <TermsContent />
      </article>
      <label>
        <input
          type="checkbox"
          checked={agreed}
          onChange={(e) => setAgreed(e.target.checked)}
        />
        I agree to the Terms of Service
      </label>
      <button type="button" onClick={submit} disabled={!agreed || isPending}>
        Continue
      </button>
    </section>
  )
}
