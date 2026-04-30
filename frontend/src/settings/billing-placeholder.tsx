import { Link } from 'react-router'

export default function BillingPlaceholder() {
  return (
    <article className="space-y-6">
      <header>
        <h1 className="text-2xl font-bold text-gray-900">Billing</h1>
        <p className="mt-1 text-sm text-gray-600">Manage your subscription and payment method.</p>
      </header>

      <section className="rounded-lg border border-dashed border-gray-300 p-8 text-center space-y-3">
        <p className="text-sm text-gray-600">
          Billing details will move into Settings soon. For now, manage your plan from the
          standalone billing page.
        </p>
        <Link
          to="/billing"
          className="inline-block rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
        >
          Go to Billing
        </Link>
      </section>
    </article>
  )
}
