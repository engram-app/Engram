import { type Environments, type Theme, type Paddle } from "@paddle/paddle-js"
import { useEffect, useState, useCallback, useRef } from "react"
import {
  CheckoutEventNames,
  type OpenCheckoutOptions,
  type CheckoutSettings,
} from "@/lib/paddle-sdk-types"
import type { CheckoutCompleteData } from "@/lib/paddle-types"
import {
  getOrCreatePaddle,
  addPaddleEventListener,
} from "@/lib/paddle-instance"

export type UseCheckoutArgs = {
  clientToken: string
  environment?: Environments
  theme?: Theme
  locale?: string
  showNonExpressPaymentMethods?: boolean
  checkoutSettings: CheckoutSettings
  onComplete?: (data: CheckoutCompleteData) => void
  onError?: (error: Error) => void
}

export function useCheckout(args: UseCheckoutArgs) {
  const {
    clientToken,
    environment = "production",
    theme,
    locale,
    showNonExpressPaymentMethods,
    checkoutSettings,
    onComplete,
    onError,
  } = args

  const [paddle, setPaddle] = useState<Paddle | null>(null)
  const [isReady, setIsReady] = useState(false)

  // Refs avoid stale closures in event listeners
  const onCompleteRef = useRef(onComplete)
  const onErrorRef = useRef(onError)

  useEffect(() => {
    onCompleteRef.current = onComplete
    onErrorRef.current = onError
  }, [onComplete, onError])

  // Subscribe to checkout.completed events
  useEffect(() => {
    const unsubscribe = addPaddleEventListener((event) => {
      if (event.name === CheckoutEventNames.CHECKOUT_COMPLETED && onCompleteRef.current) {
        onCompleteRef.current({
          transactionId: event.data?.transaction_id ?? "",
          customerId: event.data?.customer?.id ?? "",
          customerEmail: event.data?.customer?.email ?? "",
        })
      }
    })

    return unsubscribe
  }, [])

  // Initialize Paddle
  useEffect(() => {
    if (paddle || !clientToken) return

    getOrCreatePaddle(clientToken, environment)
      .then((paddleInstance) => {
        if (paddleInstance) {
          setPaddle(paddleInstance)
          setIsReady(true)
        }
      })
      .catch((error) => {
        if (onErrorRef.current) {
          onErrorRef.current(
            error instanceof Error ? error : new Error("Failed to initialize Paddle")
          )
        }
      })
  }, [clientToken, environment, paddle])

  const openCheckout = useCallback(
    (options: OpenCheckoutOptions) => {
      if (!paddle || !isReady) {
        console.warn("Paddle not initialized yet")
        return
      }

      // Normalise to items array — support both items[] and legacy priceId
      const items =
        options.items && options.items.length > 0
          ? options.items.map((item) => ({ priceId: item.priceId, quantity: item.quantity ?? 1 }))
          : [{ priceId: options.priceId, quantity: 1 }]

      paddle.Checkout.open({
        items,
        ...(options.customerAuthToken
          ? { customerAuthToken: options.customerAuthToken }
          : options.customer
            ? { customer: options.customer }
            : {}),
        ...(options.discountCode
          ? { discountCode: options.discountCode }
          : options.discountId
            ? { discountId: options.discountId }
            : {}),
        ...(options.customData && { customData: options.customData }),
        ...(options.successUrl && { successUrl: options.successUrl }),
        settings: {
          displayMode: checkoutSettings.displayMode,
          variant: checkoutSettings.variant,
          frameTarget: checkoutSettings.frameTarget,
          frameInitialHeight: checkoutSettings.frameInitialHeight,
          frameStyle: checkoutSettings.frameStyle ?? "width: 100%; border: 0;",
          ...(theme && { theme }),
          ...(locale && { locale }),
          // Not yet in @paddle/paddle-js SDK types, landing soon
          ...(showNonExpressPaymentMethods !== undefined && {
            showNonExpressPaymentMethods,
          }),
        } as Record<string, unknown>,
      })
    },
    [paddle, isReady, checkoutSettings, theme, locale, showNonExpressPaymentMethods]
  )

  const closeCheckout = useCallback(() => {
    if (paddle?.Checkout) {
      paddle.Checkout.close()
    }
  }, [paddle])

  const updateItems = useCallback(
    (items: Array<{ priceId: string; quantity: number }>) => {
      if (!paddle || !isReady) {
        console.warn("Paddle not initialized yet")
        return
      }
      ;(
        paddle.Checkout as Record<string, unknown> & { updateItems?: (items: unknown) => void }
      ).updateItems?.(items)
    },
    [paddle, isReady]
  )

  return {
    openCheckout,
    closeCheckout,
    updateItems,
    isReady,
  }
}
