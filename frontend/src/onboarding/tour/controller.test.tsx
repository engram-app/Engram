import { describe, expect, it, vi } from 'vitest'
import { render } from '@testing-library/react'
import { TourController } from './controller'

// Capture the props Joyride receives. react-joyride v3 uses a named `Joyride`
// export, not a default export, so the mock must mirror that shape.
const joyrideMock = vi.fn((_props: { run: boolean }) => null)
vi.mock('react-joyride', () => ({
  Joyride: (props: { run: boolean }) => joyrideMock(props),
  STATUS: { FINISHED: 'finished', SKIPPED: 'skipped' },
  ACTIONS: { NEXT: 'next' },
  EVENTS: { STEP_AFTER: 'step:after' },
}))

describe('TourController', () => {
  it('mounts Joyride with run=true when active', () => {
    joyrideMock.mockClear()
    render(<TourController active onExit={() => {}} reachedEnd={false} setReachedEnd={() => {}} />)
    const call = joyrideMock.mock.calls[0]?.[0]
    expect(call?.run).toBe(true)
  })

  it('mounts Joyride with run=false when inactive', () => {
    joyrideMock.mockClear()
    render(<TourController active={false} onExit={() => {}} reachedEnd={false} setReachedEnd={() => {}} />)
    const call = joyrideMock.mock.calls[0]?.[0]
    expect(call?.run).toBe(false)
  })
})
