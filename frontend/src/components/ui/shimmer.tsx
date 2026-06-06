import { cn } from '@/lib/utils'

interface Props {
  /**
   * Tailwind gradient classes for the sweep. Defaults to a brand-tint sweep
   * suited for light backgrounds. Override with e.g.
   * `'from-transparent via-white/35 to-transparent'` for dark backgrounds.
   */
  gradient?: string
  className?: string
}

const DEFAULT_GRADIENT = 'from-transparent via-primary/15 to-transparent'

/**
 * Decorative shimmer overlay. Absolute-positioned, pointer-events:none.
 * Drop inside any `relative` + `overflow-hidden` container. Drives a
 * slow gradient sweep via the `animate-shimmer-sweep` keyframe
 * defined in `main.css`.
 */
export function Shimmer({ gradient = DEFAULT_GRADIENT, className }: Props) {
  return (
    <span
      aria-hidden
      className={cn(
        'pointer-events-none absolute inset-0 animate-shimmer-sweep bg-gradient-to-r [background-size:200%_100%]',
        gradient,
        className,
      )}
    />
  )
}
