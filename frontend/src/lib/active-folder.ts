import { useQueryClient } from '@tanstack/react-query'
import { useParams } from 'react-router'
import { useActiveVaultId } from '../api/active-vault'
import type { Note } from '../api/queries'

export function useActiveFolder(): string {
  const params = useParams()
  const id = params.id ? Number(params.id) : null
  const vaultId = useActiveVaultId()
  const qc = useQueryClient()
  if (id == null || Number.isNaN(id)) return ''
  const note = qc.getQueryData<Note>(['note', vaultId, id])
  return note?.folder ?? ''
}
