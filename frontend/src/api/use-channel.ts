import { useEffect } from 'react'
import { useAuthAdapter } from '../auth/use-auth-adapter'
import { connectChannel, disconnectChannel } from './channel'
import { runCursorSync, installCursorSyncTriggers } from './cursor-sync'
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
      // Reconnect (and initial connect) → backfill missed changes via the
      // durable cursor feed. Single-flight dedupes against the mount run below.
      onSocketOpen: () => runCursorSync(vaultId, queryClient),
    })

    // Run on mount + on every window focus; returns a listener cleanup.
    const removeTriggers = installCursorSyncTriggers(vaultId, queryClient)

    return () => {
      disconnectChannel()
      removeTriggers()
    }
  }, [user?.id, vaultId, getToken])
}
