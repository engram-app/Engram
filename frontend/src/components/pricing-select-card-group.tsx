"use client"

import * as React from "react"
import { RadioGroup } from "@/components/ui/radio-group"
import { cn } from "@/lib/utils"

export type PricingSelectCardGroupProps = {
  children: React.ReactNode
  value: string
  onValueChange: (value: string) => void
  layout?: "stacked" | "grid"
  className?: string
}

export function PricingSelectCardGroup({
  children,
  value,
  onValueChange,
  layout = "stacked",
  className,
}: PricingSelectCardGroupProps) {
  const layoutClasses = {
    stacked: "flex flex-col gap-3",
    grid: "grid grid-cols-2 gap-4",
  }

  return (
    <RadioGroup
      value={value}
      onValueChange={onValueChange}
      className={cn(layoutClasses[layout], className)}
    >
      {children}
    </RadioGroup>
  )
}
