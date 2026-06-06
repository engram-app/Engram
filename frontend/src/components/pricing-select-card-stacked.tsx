"use client"

import * as React from "react"
import { RadioGroup as RadioGroupPrimitive } from "radix-ui"
import { Card, CardHeader, CardTitle } from "@/components/ui/card"
import { Badge } from "@/components/ui/badge"
import { Skeleton } from "@/components/ui/skeleton"
import { cn } from "@/lib/utils"
import type { PriceData } from "@/lib/paddle-types"

export type PricingSelectCardStackedProps = {
  priceId: string
  name: string
  priceData?: PriceData
  description?: string
  badge?: string
  badgePosition?: "left" | "center" | "right"
  icon?: React.ReactNode
  isCurrent?: boolean
  currentPlanLabel?: string
  showInterval?: boolean
  loading?: boolean
  className?: string
}

export function PricingSelectCardStacked({
  priceId,
  name,
  priceData,
  description,
  badge,
  badgePosition = "center",
  icon,
  isCurrent = false,
  currentPlanLabel = "Current plan",
  showInterval = true,
  loading = false,
  className,
}: PricingSelectCardStackedProps) {
  const { total, originalTotal, interval, trialPeriod } = priceData ?? {}

  const showBadges = badge || isCurrent

  if (loading) {
    return (
      <Card className={cn("relative p-6", className)}>
        <Skeleton className="mb-2 h-4 w-24" />
        <Skeleton className="mb-1 h-8 w-32" />
        <Skeleton className="h-3 w-16" />
        {icon && <Skeleton className="absolute top-6 right-6 h-12 w-12 rounded-lg" />}
      </Card>
    )
  }

  return (
    <RadioGroupPrimitive.Item value={priceId} disabled={isCurrent} asChild>
      <Card
        className={cn(
          "relative flex cursor-pointer flex-col overflow-visible rounded-lg border p-6 shadow-sm transition-all hover:shadow-md",
          "data-[state=checked]:border-2 data-[state=checked]:border-primary data-[state=checked]:bg-primary/5",
          isCurrent && "cursor-default border-muted bg-muted/30 hover:shadow-sm",
          className
        )}
      >
        {showBadges && (
          <div
            className={cn(
              "absolute -top-3 z-10 flex gap-1.5",
              badgePosition === "left" && "left-4",
              badgePosition === "center" && "left-1/2 -translate-x-1/2",
              badgePosition === "right" && "right-4"
            )}
          >
            {badge && <Badge className="bg-primary text-primary-foreground">{badge}</Badge>}
            {isCurrent && <Badge variant="secondary">{currentPlanLabel}</Badge>}
          </div>
        )}

        <div className="flex items-start justify-between">
          <CardHeader className="p-0">
            <div className="text-muted-foreground mb-1 text-sm">{description || name}</div>
            {originalTotal && (
              <div className="text-muted-foreground text-sm line-through">{originalTotal}</div>
            )}
            <CardTitle className="text-3xl font-bold">{total}</CardTitle>
            {showInterval && interval && (
              <div className="text-muted-foreground text-sm">per {interval}</div>
            )}
            {trialPeriod && (
              <div className="text-muted-foreground text-xs mt-1">{trialPeriod} free trial</div>
            )}
          </CardHeader>

          {icon && <div className="h-12 w-12 shrink-0 rounded-lg">{icon}</div>}
        </div>
      </Card>
    </RadioGroupPrimitive.Item>
  )
}
