import { describe, expect, it, vi } from 'vitest'
import { render } from '@testing-library/react'
import { TourController } from './controller'

const driveMock = { drive: vi.fn(), destroy: vi.fn() }
vi.mock('driver.js', () => ({ driver: vi.fn(() => driveMock) }))

describe('TourController', () => {
  it('starts driver.js on mount when active=true', () => {
    render(<TourController active onExit={() => {}} reachedEnd={false} setReachedEnd={() => {}} />)
    expect(driveMock.drive).toHaveBeenCalled()
  })

  it('does nothing when active=false', () => {
    driveMock.drive.mockClear()
    render(<TourController active={false} onExit={() => {}} reachedEnd={false} setReachedEnd={() => {}} />)
    expect(driveMock.drive).not.toHaveBeenCalled()
  })
})
