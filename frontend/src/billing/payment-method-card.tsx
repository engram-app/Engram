import { Button } from '@/components/ui/button'
import type { PaymentMethod } from '../api/queries'

function formatExpiry(month: number | null, year: number | null): string | null {
  if (!month || !year) return null
  return `${String(month).padStart(2, '0')}/${year}`
}

export default function PaymentMethodCard({
  paymentMethod,
  onUpdate,
  updating = false,
}: {
  paymentMethod: PaymentMethod | null
  onUpdate: () => void
  updating?: boolean
}) {
  const expiry = formatExpiry(paymentMethod?.exp_month ?? null, paymentMethod?.exp_year ?? null)

  return (
    <section className="space-y-4 rounded-lg border border-border bg-card p-6">
      <header className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-foreground">Payment method</h2>
        <Button variant="outline" size="sm" onClick={onUpdate} disabled={updating}>
          Update
        </Button>
      </header>

      {paymentMethod?.last4 ? (
        <p className="text-sm text-muted-foreground">
          <span className="font-medium capitalize text-foreground">{paymentMethod.card_brand}</span>
          {' •••• '}
          {paymentMethod.last4}
          {expiry && <span> · expires {expiry}</span>}
        </p>
      ) : (
        <p className="text-sm text-muted-foreground">No payment method on file.</p>
      )}
    </section>
  )
}
