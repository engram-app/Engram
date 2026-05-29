import { cn } from '@/lib/utils'

// Single source of truth for repeated Tailwind class patterns across the
// auth / onboarding / consent / settings surfaces. Keep visual changes here.

// Section/page heading used on the branded surfaces.
export const heading = 'text-2xl font-bold tracking-tight text-foreground sm:text-3xl'

// Base text input. Standalone usage applies it directly; inputs that sit under
// a label caption add the `mt-1 block` layout via cn().
export const fieldInput =
  'w-full rounded-lg border border-input bg-background px-3 py-2 text-sm text-foreground outline-none transition-colors focus-visible:border-primary'

// Destructive alert box (title + body). Single-line inline errors tighten the
// padding with cn(destructiveAlert, 'p-3 ...').
export const destructiveAlert =
  'rounded-lg border border-destructive/50 bg-destructive/5 p-4 text-sm'

// Selectable bordered row (radio / checkbox card) with active highlight.
export function selectableRow(active: boolean): string {
  return cn(
    'flex cursor-pointer items-center gap-3 rounded-lg border p-4 transition-colors',
    active ? 'border-primary bg-primary/5' : 'border-border hover:border-primary/50',
  )
}
