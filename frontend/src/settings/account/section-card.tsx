import type { ReactNode } from 'react'

interface Props {
  title: string
  description?: string
  children: ReactNode
}

export function SettingsSectionCard({ title, description, children }: Props) {
  return (
    <section className="rounded-lg border border-border bg-card p-4 sm:p-6">
      <header className="mb-4">
        <h2 className="text-base font-semibold text-foreground">{title}</h2>
        {description && (
          <p className="mt-1 text-sm text-muted-foreground">{description}</p>
        )}
      </header>
      {children}
    </section>
  )
}
