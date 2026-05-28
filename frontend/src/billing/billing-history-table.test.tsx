import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import BillingHistoryTable from './billing-history-table'
import type { BillingTransaction } from '../api/queries'

const txns: BillingTransaction[] = [
  {
    id: 'txn_2',
    billed_at: '2026-05-27T07:00:00Z',
    amount: '2000',
    currency: 'USD',
    status: 'completed',
    invoice_id: 'inv_2',
  },
  {
    id: 'txn_1',
    billed_at: '2026-04-27T07:00:00Z',
    amount: '2000',
    currency: 'USD',
    status: 'past_due',
    invoice_id: 'inv_1',
  },
]

describe('BillingHistoryTable', () => {
  it('renders a row per transaction with formatted amount and status', () => {
    render(<BillingHistoryTable transactions={txns} onDownload={() => {}} />)
    expect(screen.getAllByText('$20.00')).toHaveLength(2)
    expect(screen.getByText(/completed/i)).toBeInTheDocument()
    expect(screen.getByText(/past due/i)).toBeInTheDocument()
  })

  it('shows an empty state when there are no transactions', () => {
    render(<BillingHistoryTable transactions={[]} onDownload={() => {}} />)
    expect(screen.getByText(/no transactions/i)).toBeInTheDocument()
  })

  it('calls onDownload with the transaction id', async () => {
    const onDownload = vi.fn()
    render(<BillingHistoryTable transactions={txns} onDownload={onDownload} />)
    const [firstDownload] = screen.getAllByRole('button', { name: /download/i })
    fireEvent.click(firstDownload as HTMLElement)
    expect(onDownload).toHaveBeenCalledWith('txn_2')
  })
})
