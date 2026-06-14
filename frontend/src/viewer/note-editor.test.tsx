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
let lastOnChange: ((value: string) => void) | undefined

vi.mock('@uiw/react-codemirror', () => ({
  default: (props: {
    extensions: unknown
    value: string
    onChange?: (value: string) => void
    onCreateEditor?: (view: unknown) => void
  }) => {
    capturedExtensions.push(props.extensions)
    lastOnChange = props.onChange
    // Real @uiw fires onChange synchronously from the update listener on every
    // dispatch (unless the txn carries its ExternalChange annotation). Mirror
    // that so we can prove applyRemote's echo is suppressed.
    lastDispatch = vi.fn(() => props.onChange?.('echoed-from-dispatch'))
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

  it('suppresses the onChange echo from applyRemote (no autosave feedback loop)', () => {
    const onChange = vi.fn()
    const ref = createRef<NoteEditorHandle>()
    render(<NoteEditor ref={ref} value="abc" onChange={onChange} />)

    // applyRemote -> dispatch -> @uiw fires onChange; the wrapper must swallow it.
    ref.current!.applyRemote('abXc')

    expect(lastDispatch).toHaveBeenCalledTimes(1)
    expect(onChange).not.toHaveBeenCalled()
  })

  it('passes genuine user edits through onChange', () => {
    const onChange = vi.fn()
    render(<NoteEditor value="a" onChange={onChange} />)

    lastOnChange?.('typed by user')

    expect(onChange).toHaveBeenCalledWith('typed by user')
  })
})
