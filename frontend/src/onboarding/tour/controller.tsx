import { useEffect, useRef, useState } from 'react'
import { Joyride, type EventData, type Step, STATUS, EVENTS, ACTIONS } from 'react-joyride'
import { tourSteps, GATED_STEP_INDEXES } from './steps'

interface Props {
  active: boolean
  onExit: (reachedEnd: boolean) => void
  reachedEnd: boolean
  setReachedEnd: (v: boolean) => void
}

export function TourController({ active, onExit, setReachedEnd }: Props) {
  // Stash callbacks behind refs so React-Joyride's event handler always sees
  // the latest closures without us re-mounting on every parent render.
  const onExitRef = useRef(onExit)
  const setReachedEndRef = useRef(setReachedEnd)
  onExitRef.current = onExit
  setReachedEndRef.current = setReachedEnd

  // Controlled stepIndex so we can advance gated steps from a target click
  // listener (joyride's continuous mode otherwise drives index internally).
  const [stepIndex, setStepIndex] = useState(0)

  // Reset to first step whenever the tour (re)starts.
  useEffect(() => {
    if (active) setStepIndex(0)
  }, [active])

  // Gated steps: hide the Next button + advance only when the user actually
  // clicks the highlighted target. Attach a one-shot listener on the target
  // element while we're parked on a gated step.
  useEffect(() => {
    if (!active) return
    if (!GATED_STEP_INDEXES.has(stepIndex)) return

    const step = tourSteps[stepIndex]
    if (!step) return
    const target = document.querySelector(step.target as string)
    if (!target) return

    const handler = () => setStepIndex((i) => i + 1)
    target.addEventListener('click', handler, { once: true })
    return () => target.removeEventListener('click', handler)
  }, [active, stepIndex])

  const handle = (data: EventData) => {
    const { status, index, action, type } = data

    if (type === EVENTS.STEP_AFTER) {
      if (action === ACTIONS.NEXT) {
        if (index === tourSteps.length - 1) {
          setReachedEndRef.current(true)
          onExitRef.current(true)
          return
        }
        setStepIndex(index + 1)
      } else if (action === ACTIONS.PREV) {
        setStepIndex(Math.max(0, index - 1))
      }
      return
    }

    if (status === STATUS.FINISHED || status === STATUS.SKIPPED) {
      onExitRef.current(status === STATUS.FINISHED)
    }
  }

  return (
    <Joyride
      steps={tourSteps as Step[]}
      run={active}
      stepIndex={stepIndex}
      continuous
      onEvent={handle}
      locale={{ last: 'Create my vault', skip: 'Skip' }}
      options={{
        showProgress: true,
        zIndex: 60, // sits above shadcn dialogs (z-50)
        // ESC closes; overlay click is a no-op (no overlay dismissal).
        overlayClickAction: false,
        // Show skip button alongside back+primary.
        buttons: ['skip', 'back', 'primary'],
        // Pick up the design tokens. CSS vars are HSL triplets in this app
        // (see frontend/src/index.css or main.css). Wrap with hsl() so the
        // browser parses them as colors rather than raw triplets.
        primaryColor: 'hsl(var(--primary))',
        backgroundColor: 'hsl(var(--popover))',
        textColor: 'hsl(var(--popover-foreground))',
        arrowColor: 'hsl(var(--popover))',
        overlayColor: 'rgba(0, 0, 0, 0.45)',
      }}
    />
  )
}
