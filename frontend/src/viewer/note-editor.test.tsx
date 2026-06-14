import { createRef } from 'react'
import { describe, expect, it, vi } from 'vitest'
import { render } from '@testing-library/react'

import NoteEditor, { type NoteEditorHandle } from './note-editor'

// Captures the extensions prop identity per render + the onCreateEditor cb.
// @uiw/react-codemirror watches the extensions prop and reconfigures the
// editor whenever its identity changes — a fresh array per keystroke
// reconfigures continuously while typing.
const capturedExtensions: unknown[] = []
let lastDispatch: ReturnType<typeof vi.fn>

vi.mock('@uiw/react-codemirror', () => ({
  default: (props: {
    extensions: unknown
    value: string
    onCreateEditor?: (view: unknown) => void
  }) => {
    capturedExtensions.push(props.extensions)
    lastDispatch = vi.fn()
    // Hand back a minimal EditorView-shaped object so the imperative handle
    // can read the doc + dispatch a change.
    const fakeView = {
      state: { doc: { toString: () => props.value } },
      dispatch: lastDispatch,
    }
    props.onCreateEditor?.(fakeView)
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

describe('NoteEditor imperative applyRemote', () => {
  it('dispatches a minimal replacement, not a full reset', () => {
    const ref = createRef<NoteEditorHandle>()
    render(<NoteEditor ref={ref} value="abcXYZdef" onChange={() => {}} />)

    ref.current!.applyRemote('abcQQdef')

    expect(lastDispatch).toHaveBeenCalledTimes(1)
    expect(lastDispatch).toHaveBeenCalledWith({
      changes: { from: 3, to: 6, insert: 'QQ' },
    })
  })

  it('is a no-op when remote text equals the current doc', () => {
    const ref = createRef<NoteEditorHandle>()
    render(<NoteEditor ref={ref} value="same" onChange={() => {}} />)

    ref.current!.applyRemote('same')

    expect(lastDispatch).not.toHaveBeenCalled()
  })
})
