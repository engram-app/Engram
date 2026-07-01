import { describe, expect, test, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { PropertyTypeMenu } from './property-type-menu'

describe('PropertyTypeMenu', () => {
  test('shows current type and emits a new one on select', async () => {
    const onChange = vi.fn()
    render(<PropertyTypeMenu value="text" onChange={onChange} />)
    const trigger = screen.getByRole('button', { name: /property type/i })
    // Radix DropdownMenu opens on pointerdown in happy-dom
    fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false })
    fireEvent.click(trigger)
    const item = await screen.findByRole('menuitem', { name: 'list' })
    fireEvent.click(item)
    expect(onChange).toHaveBeenCalledWith('list')
  })
})
