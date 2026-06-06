"use client"

import { TrendingDown, TrendingUp, Minus } from "lucide-react"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Skeleton } from "@/components/ui/skeleton"
import { Separator } from "@/components/ui/separator"
import { cn } from "@/lib/utils"
import type {
  PlanChangeBreakdownData,
  PlanChangeTransactionSectionData,
} from "@/lib/paddle-types"
import {
  formatMoney,
  formatDate,
} from "@/lib/paddle-format"

/** Props for the `PlanChangeBreakdown` component. */
export type PlanChangeBreakdownProps = {
  breakdown?: PlanChangeBreakdownData
  /**
   * Payment collection mode. From `subscription.collection_mode`.
   * Affects section titles: "Charged Today" vs "Invoice Created" for immediate transactions.
   */
  collectionMode?: "automatic" | "manual"
  className?: string
}

const SECTION_TITLES: Record<
  "immediate" | "next" | "recurring",
  { automatic: string; manual: string }
> = {
  immediate: { automatic: "Charged today", manual: "Invoice created" },
  next: { automatic: "Next invoice", manual: "Next invoice" },
  recurring: { automatic: "Ongoing billing", manual: "Ongoing billing" },
}

function TransactionSection({
  section,
  kind,
  collectionMode = "automatic",
  currency,
}: {
  section: PlanChangeTransactionSectionData
  kind: "immediate" | "next" | "recurring"
  collectionMode?: "automatic" | "manual"
  currency: string
}) {
  const title = SECTION_TITLES[kind][collectionMode]

  const description =
    kind === "immediate"
      ? collectionMode === "manual"
        ? "An invoice will be created for this amount"
        : "This amount will be charged immediately"
      : kind === "next"
        ? section.billingDate
          ? `Charged on ${formatDate(section.billingDate)}`
          : undefined
        : "Recurring amount after this change"

  return (
    <div className="flex flex-col gap-3">
      <div>
        <h4 className="text-sm font-medium">{title}</h4>
        {description && <p className="text-xs text-muted-foreground">{description}</p>}
      </div>

      <div className="flex flex-col gap-2">
        {section.lineItems.map((item, index) => (
          <div key={index} className="flex items-start justify-between gap-4 text-sm">
            <div className="flex flex-col gap-0.5 min-w-0">
              <span className="font-medium truncate">{item.productName}</span>
              <span className="text-xs text-muted-foreground">
                {item.quantity > 1 && `${item.quantity} \u00d7 `}
                {formatMoney(item.unitPrice, currency)}
                {item.isProrated && (
                  <Badge variant="secondary" className="ml-1 text-[10px] px-1 py-0">
                    Prorated
                  </Badge>
                )}
              </span>
              {item.prorationPeriod && (
                <span className="text-xs text-muted-foreground">{item.prorationPeriod}</span>
              )}
            </div>
            <span className="tabular-nums shrink-0">{formatMoney(item.total, currency)}</span>
          </div>
        ))}
      </div>

      <Separator />

      <dl className="flex flex-col gap-1.5 text-sm">
        <div className="flex justify-between gap-4">
          <dt className="text-muted-foreground">Subtotal</dt>
          <dd className="tabular-nums">{formatMoney(section.totals.subtotal, currency)}</dd>
        </div>
        {section.totals.discount !== undefined && (
          <div className="flex justify-between gap-4">
            <dt className="text-success-foreground">Discount</dt>
            <dd className="tabular-nums text-success-foreground">
              −{formatMoney(section.totals.discount, currency)}
            </dd>
          </div>
        )}
        <div className="flex justify-between gap-4">
          <dt className="text-muted-foreground">Tax</dt>
          <dd className="tabular-nums">{formatMoney(section.totals.tax, currency)}</dd>
        </div>
        {section.totals.credit !== undefined && (
          <div className="flex justify-between gap-4">
            <dt className="text-success-foreground">Credit applied</dt>
            <dd className="tabular-nums text-success-foreground">
              −{formatMoney(section.totals.credit, currency)}
            </dd>
          </div>
        )}
        {section.totals.creditToBalance !== undefined && (
          <div className="flex justify-between gap-4">
            <dt className="text-success-foreground">Credit to balance</dt>
            <dd className="tabular-nums text-success-foreground">
              {formatMoney(section.totals.creditToBalance, currency)}
            </dd>
          </div>
        )}
        <div className="flex justify-between gap-4 pt-1.5 border-t font-medium">
          <dt>Total</dt>
          <dd className="tabular-nums">{formatMoney(section.totals.total, currency)}</dd>
        </div>
      </dl>
    </div>
  )
}

export function PlanChangeBreakdown({
  breakdown,
  collectionMode,
  className,
}: PlanChangeBreakdownProps) {
  if (!breakdown) {
    return <PlanChangeBreakdownSkeleton className={className} />
  }

  const {
    currency,
    result,
    breakdown: summaryBreakdown,
    immediateTransaction,
    nextTransaction,
    recurringTransaction,
  } = breakdown
  const isCredit = result.direction === "credit"
  const isNone = result.direction === "none"

  const resultLabel = isNone
    ? "No charge"
    : isCredit
      ? "Credit to account"
      : immediateTransaction
        ? "Amount due"
        : "Added to next bill"

  return (
    <Card className={cn("flex flex-col", className)}>
      <CardHeader>
        <CardTitle className="text-base font-semibold">Change summary</CardTitle>
        <CardDescription>Review the financial impact of this change</CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-6">
        <div
          className={cn(
            "flex items-center justify-between rounded-lg p-4",
            isCredit ? "bg-success/10" : "bg-muted"
          )}
        >
          <div className="flex items-center gap-2">
            {isCredit ? (
              <TrendingDown className="size-5 text-success-foreground" />
            ) : isNone ? (
              <Minus className="size-5 text-muted-foreground" />
            ) : (
              <TrendingUp className="size-5 text-foreground" />
            )}
            <span className="font-medium">{resultLabel}</span>
          </div>
          <span
            className={cn("text-lg font-bold tabular-nums", isCredit && "text-success-foreground")}
          >
            {isCredit
              ? `−${formatMoney(result.amount, currency)}`
              : formatMoney(result.amount, currency)}
          </span>
        </div>

        {/* Credit/charge breakdown from update_summary */}
        {summaryBreakdown &&
          (summaryBreakdown.credit !== undefined || summaryBreakdown.charge !== undefined) && (
            <div className="flex flex-col gap-2 text-sm">
              {summaryBreakdown.credit !== undefined && (
                <div className="flex items-center justify-between gap-4">
                  <span className="text-muted-foreground">Credit from current plan</span>
                  <span className="text-success-foreground tabular-nums">
                    −{formatMoney(summaryBreakdown.credit, currency)}
                  </span>
                </div>
              )}
              {summaryBreakdown.charge !== undefined && (
                <div className="flex items-center justify-between gap-4">
                  <span className="text-muted-foreground">Charge for new plan</span>
                  <span className="tabular-nums">
                    {formatMoney(summaryBreakdown.charge, currency)}
                  </span>
                </div>
              )}
            </div>
          )}

        {immediateTransaction && (
          <>
            <Separator />
            <TransactionSection
              section={immediateTransaction}
              kind="immediate"
              collectionMode={collectionMode}
              currency={currency}
            />
          </>
        )}

        {nextTransaction && (
          <>
            <Separator />
            <TransactionSection
              section={nextTransaction}
              kind="next"
              collectionMode={collectionMode}
              currency={currency}
            />
          </>
        )}

        {recurringTransaction && (
          <>
            <Separator />
            <TransactionSection
              section={recurringTransaction}
              kind="recurring"
              collectionMode={collectionMode}
              currency={currency}
            />
          </>
        )}
      </CardContent>
    </Card>
  )
}

function PlanChangeBreakdownSkeleton({ className }: { className?: string }) {
  return (
    <Card className={cn("flex flex-col", className)}>
      <CardHeader>
        <Skeleton className="h-4 w-32" />
        <Skeleton className="h-3 w-56" />
      </CardHeader>
      <CardContent className="flex flex-col gap-6">
        <div className="rounded-lg bg-muted p-4 flex items-center justify-between">
          <div className="flex items-center gap-2">
            <Skeleton className="h-5 w-5 rounded" />
            <Skeleton className="h-4 w-28" />
          </div>
          <Skeleton className="h-6 w-16" />
        </div>

        <div className="space-y-2">
          <div className="flex justify-between gap-4">
            <Skeleton className="h-3 w-36" />
            <Skeleton className="h-3 w-16" />
          </div>
          <div className="flex justify-between gap-4">
            <Skeleton className="h-3 w-32" />
            <Skeleton className="h-3 w-16" />
          </div>
        </div>

        <Separator />

        <div className="space-y-3">
          <div className="space-y-1">
            <Skeleton className="h-4 w-24" />
            <Skeleton className="h-3 w-48" />
          </div>
          <div className="space-y-2">
            <div className="flex justify-between gap-4">
              <div className="space-y-1">
                <Skeleton className="h-4 w-20" />
                <Skeleton className="h-3 w-16" />
              </div>
              <Skeleton className="h-4 w-14" />
            </div>
          </div>
          <Separator />
          <div className="space-y-1.5">
            <div className="flex justify-between gap-4">
              <Skeleton className="h-3 w-16" />
              <Skeleton className="h-3 w-14" />
            </div>
            <div className="flex justify-between gap-4">
              <Skeleton className="h-3 w-8" />
              <Skeleton className="h-3 w-10" />
            </div>
            <div className="flex justify-between gap-4 pt-1.5 border-t">
              <Skeleton className="h-4 w-12" />
              <Skeleton className="h-4 w-14" />
            </div>
          </div>
        </div>

        <Separator />

        <div className="space-y-3">
          <div className="space-y-1">
            <Skeleton className="h-4 w-28" />
            <Skeleton className="h-3 w-52" />
          </div>
          <div className="space-y-2">
            <div className="flex justify-between gap-4">
              <div className="space-y-1">
                <Skeleton className="h-4 w-20" />
                <Skeleton className="h-3 w-16" />
              </div>
              <Skeleton className="h-4 w-14" />
            </div>
          </div>
          <Separator />
          <div className="space-y-1.5">
            <div className="flex justify-between gap-4">
              <Skeleton className="h-3 w-16" />
              <Skeleton className="h-3 w-14" />
            </div>
            <div className="flex justify-between gap-4">
              <Skeleton className="h-3 w-8" />
              <Skeleton className="h-3 w-10" />
            </div>
            <div className="flex justify-between gap-4 pt-1.5 border-t">
              <Skeleton className="h-4 w-12" />
              <Skeleton className="h-4 w-14" />
            </div>
          </div>
        </div>
      </CardContent>
    </Card>
  )
}
