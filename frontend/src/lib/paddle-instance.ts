import {
  initializePaddle,
  type Environments,
  type Paddle,
  type PaddleEventData,
} from "@paddle/paddle-js"

type PaddleEventListener = (event: PaddleEventData) => void

// Module-level singleton state
let paddlePromise: Promise<Paddle | undefined> | null = null
let currentToken: string | null = null
const eventListeners = new Set<PaddleEventListener>()

/**
 * Returns a shared Paddle instance, initializing once per token.
 * Uses a dispatcher eventCallback so multiple hooks can subscribe to events.
 */
export function getOrCreatePaddle(
  token: string,
  environment: Environments
): Promise<Paddle | undefined> {
  if (paddlePromise && currentToken === token) {
    return paddlePromise
  }

  currentToken = token
  paddlePromise = initializePaddle({
    token,
    environment,
    eventCallback: (event) => {
      eventListeners.forEach((listener) => listener(event))
    },
  })

  return paddlePromise
}

/** Subscribe to Paddle events. Returns an unsubscribe function. */
export function addPaddleEventListener(listener: PaddleEventListener): () => void {
  eventListeners.add(listener)
  return () => {
    eventListeners.delete(listener)
  }
}
