import { describe, expect, test } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import * as Y from 'yjs'
import { addKey, readRows, setValue } from '../crdt/frontmatter-doc'
import { PropertiesWidget } from './properties-widget'

describe('PropertiesWidget', () => {
  test('renders rows from the doc and writes value edits back', async () => {
    const doc = new Y.Doc()
    addKey(doc, 'title', 'text')
    setValue(doc, 'title', 'Hi')
    render(<PropertiesWidget doc={doc} />)
    const input = await screen.findByDisplayValue('Hi')
    fireEvent.change(input, { target: { value: 'Bye' } })
    fireEvent.blur(input)
    expect(readRows(doc).find((r) => r.key === 'title')?.value).toBe('Bye')
  })

  test('reflects a remote add live', async () => {
    const doc = new Y.Doc()
    render(<PropertiesWidget doc={doc} />)
    addKey(doc, 'author', 'text') // simulate remote mutation
    await waitFor(() => expect(screen.getByText('author')).toBeInTheDocument())
  })

  test('add property row appends a key', async () => {
    const doc = new Y.Doc()
    render(<PropertiesWidget doc={doc} />)
    fireEvent.change(screen.getByPlaceholderText('Property name'), { target: { value: 'status' } })
    fireEvent.click(screen.getByRole('button', { name: /add property/i }))
    await waitFor(() => expect(readRows(doc).map((r) => r.key)).toContain('status'))
  })

  test('does not clobber a field being actively edited by a remote update', async () => {
    const doc = new Y.Doc()
    addKey(doc, 'title', 'text')
    setValue(doc, 'title', 'Hi')
    render(<PropertiesWidget doc={doc} />)
    const input = (await screen.findByDisplayValue('Hi')) as HTMLInputElement
    input.focus()
    fireEvent.change(input, { target: { value: 'Draft' } })
    setValue(doc, 'title', 'RemoteWins') // remote update while focused
    await waitFor(() =>
      expect(readRows(doc).find((r) => r.key === 'title')?.value).toBe('RemoteWins'),
    )
    expect(input.value).toBe('Draft') // local draft preserved while focused
  })
})
