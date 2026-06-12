import { describe, expect, it, vi } from 'vitest'
import { render } from '@testing-library/react'

import NoteEditor from './note-editor'

// Captures the extensions prop identity per render. @uiw/react-codemirror
// watches this prop and dispatches a full reconfigure effect whenever its
// identity changes — a fresh array per keystroke reconfigures the editor
// continuously while typing.
const capturedExtensions: unknown[] = []

vi.mock('@uiw/react-codemirror', () => ({
  default: (props: { extensions: unknown }) => {
    capturedExtensions.push(props.extensions)
    return <div data-testid="cm" />
  },
}))

vi.mock('../theme/theme-provider', () => ({
  useTheme: () => ({ resolved: 'light' }),
}))

describe('NoteEditor extensions stability', () => {
  it('passes a referentially stable extensions array across re-renders', () => {
    capturedExtensions.length = 0
    const onChange = () => {}

    const { rerender } = render(<NoteEditor value="a" onChange={onChange} />)
    rerender(<NoteEditor value="ab" onChange={onChange} />)
    rerender(<NoteEditor value="abc" onChange={onChange} />)

    expect(capturedExtensions).toHaveLength(3)
    expect(capturedExtensions[1]).toBe(capturedExtensions[0])
    expect(capturedExtensions[2]).toBe(capturedExtensions[0])
  })
})
