import { useEffect, useRef, useState } from 'react'
import { Joyride, type EventData, type Step, STATUS, EVENTS, ACTIONS } from 'react-joyride'
import { tourSteps, GATED_STEPS } from './steps'

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

  // Gated steps: hide the Next button + advance only when the user performs
  // the configured interaction. The step declares which window CustomEvent
  // signals success (e.g. step 0 waits for `engram:vault-switched`).
  useEffect(() => {
    if (!active) return
    const eventName = GATED_STEPS[stepIndex]
    if (!eventName) return

    const handler = () => setStepIndex((i) => i + 1)
    window.addEventListener(eventName, handler, { once: true })
    return () => window.removeEventListener(eventName, handler)
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
        // Pick up the design tokens. In this app the CSS vars are full
        // oklch() colors (see frontend/src/main.css), so reference them
        // directly — wrapping in hsl() yields invalid CSS and the popover
        // background falls back to transparent.
        primaryColor: 'var(--primary)',
        backgroundColor: 'var(--popover)',
        textColor: 'var(--popover-foreground)',
        arrowColor: 'var(--popover)',
        overlayColor: 'rgba(0, 0, 0, 0.45)',
      }}
    />
  )
}
