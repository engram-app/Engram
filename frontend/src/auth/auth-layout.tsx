import type { ReactNode } from 'react'

export default function AuthLayout({ children }: { children: ReactNode }) {
  return (
    <main className="relative flex min-h-screen items-center justify-center overflow-hidden bg-background text-foreground">
      <div className="pointer-events-none absolute inset-0 z-0 overflow-hidden" aria-hidden="true">
        <div className="absolute inset-0 grid-overlay opacity-30" />
        <div className="absolute -left-32 -top-32 h-96 w-96 neural-glow-purple opacity-60" />
        <div className="absolute -bottom-32 -right-32 h-96 w-96 neural-glow-cyan opacity-60" />
      </div>
      <div className="relative z-10 flex w-full items-center justify-center px-4 py-12">
        {children}
      </div>
    </main>
  )
}
