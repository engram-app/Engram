import { useState } from 'react'
import { useNavigate } from 'react-router'
import { useAcceptTerms, useOnboardingStatus } from '../api/queries'
import { TERMS_VERSION, TermsContent } from '../legal/terms-of-service'

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
    <section className="mx-auto flex max-w-2xl flex-col gap-6 p-6">
      <article className="prose dark:prose-invert max-h-[60vh] overflow-y-auto rounded-lg border border-gray-200 bg-white p-6 dark:border-gray-700 dark:bg-gray-900">
        <TermsContent />
      </article>
      <label className="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={agreed}
          onChange={(e) => setAgreed(e.target.checked)}
          className="h-4 w-4 rounded border-gray-300"
        />
        I agree to the Terms of Service
      </label>
      <button
        type="button"
        onClick={submit}
        disabled={!agreed || isPending}
        className="w-full rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-gray-400"
      >
        {isPending ? 'Saving…' : 'Continue'}
      </button>
    </section>
  )
}
