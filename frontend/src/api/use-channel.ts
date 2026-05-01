import { useEffect } from 'react'
import { useAuthAdapter } from '../auth/use-auth-adapter'
import { connectChannel, disconnectChannel } from './channel'
import { queryClient } from './query-client'
import { useMe } from './queries'
import { useActiveVaultId } from './active-vault'

export function useChannel() {
  const { getToken } = useAuthAdapter()
  const { data: user } = useMe()
  const vaultId = useActiveVaultId()

  useEffect(() => {
    if (!user || vaultId == null) return

    connectChannel({
      userId: user.id,
      vaultId,
      getToken: () => getToken(),
      queryClient,
    })

    return () => disconnectChannel()
  }, [user?.id, vaultId, getToken])
}
