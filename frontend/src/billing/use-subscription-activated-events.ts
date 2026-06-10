import { useEffect } from 'react'
import { Socket } from 'phoenix'
import { useAuthAdapter } from '../auth/use-auth-adapter'
import { getWsBase, joinWsUrl } from '../api/base'

export interface SubscriptionActivatedPayload {
  tier: string
  status: string
  subscription_id: string
}

interface Options {
  userId: number | null | undefined
  enabled: boolean
  onActivated: (payload: SubscriptionActivatedPayload) => void
}

/**
 * Subscribes to `user:{id}` for `subscription_activated` broadcasts. Fires
 * `onActivated` when the Paddle webhook flips the user's subscription to
 * trialing/active server-side (or when activated/updated events land for
 * existing subs). Replaces the prior polling-based activation watcher.
 *
 * Mirrors `useVaultReadyEvents` — same channel topic, same socket
 * lifecycle, same auth pattern.
 */
export function useSubscriptionActivatedEvents({
  userId,
  enabled,
  onActivated,
}: Options): void {
  const { getToken } = useAuthAdapter()

  useEffect(() => {
    if (!enabled || userId == null) return

    let socket: Socket | null = null
    let cancelled = false

    async function connect() {
      const token = await getToken()
      if (cancelled || !token) return

      socket = new Socket(joinWsUrl(getWsBase(), '/socket'), { params: { token } })
      socket.connect()

      const channel = socket.channel(`user:${userId}`)

      channel.on('subscription_activated', (payload: SubscriptionActivatedPayload) => {
        onActivated(payload)
      })

      channel.join().receive('error', (resp) => {
        console.error('user channel join failed (subscription activation listener)', resp)
      })
    }

    connect()

    return () => {
      cancelled = true
      if (socket) socket.disconnect()
    }
  }, [userId, enabled, getToken, onActivated])
}
