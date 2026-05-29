import type { ReactNode } from 'react'
import { cn } from '@/lib/utils'

type AuthPanelProps = {
  children: ReactNode
  className?: string
}

export default function AuthPanel({ children, className }: AuthPanelProps) {
  return (
    <section className="m-auto w-full max-w-2xl px-4 py-6">
      <div
        className={cn(
          'rounded-2xl border border-border bg-background p-5 sm:p-6',
          className,
        )}
      >
        {children}
      </div>
    </section>
  )
}
