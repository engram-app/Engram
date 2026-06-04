import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { CreateFirstVaultModal } from './create-first-vault-modal'

vi.mock('../components/vault-create-form', () => ({
  VaultCreateForm: ({ onCreated }: { onCreated: (id: number) => void }) => (
    <button onClick={() => onCreated(1)}>fake-create</button>
  ),
}))

describe('CreateFirstVaultModal', () => {
  it('renders heading; ESC does nothing; onCreated bubbles', () => {
    const onCreated = vi.fn()
    render(<CreateFirstVaultModal onCreated={onCreated} />)

    expect(screen.getByRole('heading', { name: /first vault/i })).toBeInTheDocument()

    fireEvent.keyDown(document, { key: 'Escape' })
    expect(screen.getByRole('heading', { name: /first vault/i })).toBeInTheDocument()

    fireEvent.click(screen.getByText('fake-create'))
    expect(onCreated).toHaveBeenCalledWith(1)
  })
})
