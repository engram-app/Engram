import { useEffect, useRef } from 'react'
import { driver, type Driver } from 'driver.js'
import { tourSteps } from './steps'

interface Props {
  active: boolean
  onExit: (reachedEnd: boolean) => void
  reachedEnd: boolean
  setReachedEnd: (v: boolean) => void
}

export function TourController({ active, onExit, setReachedEnd }: Props) {
  const drvRef = useRef<Driver | null>(null)
  const reachedRef = useRef(false)

  useEffect(() => {
    if (!active) return

    const drv = driver({
      showProgress: true,
      steps: tourSteps,
      onHighlighted: (_el, _step, opts) => {
        if (opts.state.activeIndex === tourSteps.length - 1) {
          reachedRef.current = true
          setReachedEnd(true)
        }
      },
      onDestroyed: () => {
        onExit(reachedRef.current)
      },
    })

    drvRef.current = drv
    drv.drive()

    return () => {
      drv.destroy()
    }
  }, [active, onExit, setReachedEnd])

  return null
}
