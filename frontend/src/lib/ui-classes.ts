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

// Call-to-action button color pairs. `ctaFilled` is the strong primary action;
// `ctaOutline` is the quieter secondary. Both are color/interaction only — pair
// with layout classes (rounded/px/py/text) at the call site via cn().
export const ctaFilled = 'bg-primary text-primary-foreground hover:bg-primary/90'
export const ctaOutline =
  'border border-input bg-transparent text-foreground hover:bg-accent'

// Selectable bordered row (radio / checkbox card) with active highlight.
// `compact` tightens padding for dense lists (e.g. the onboarding tool picker);
// the default keeps roomy padding for standalone rows (e.g. an agree checkbox).
export function selectableRow(active: boolean, compact = false): string {
  return cn(
    'flex cursor-pointer items-center gap-3 rounded-lg border transition-colors',
    compact ? 'p-2.5' : 'p-4',
    active ? 'border-primary bg-primary/5' : 'border-border hover:border-primary/50',
  )
}
