import * as React from "react";

("use client");

import { CheckoutSummary } from "@/components/checkout-summary";
import { useCheckout } from "@/hooks/use-checkout";
import { mapCheckoutEventsToSummary } from "@/lib/checkout-summary-utils";
import { addPaddleEventListener } from "@/lib/paddle-instance";
import {
	type CheckoutCustomer,
	CheckoutEventNames,
	type CheckoutEventsData,
	type CheckoutOpenLineItem,
	type Environments,
	type PaddleEventData,
} from "@/lib/paddle-sdk-types";
import type { CheckoutCompleteData, CheckoutSummaryData } from "@/lib/paddle-types";
import { cn } from "@/lib/utils";

const INLINE_CHECKOUT_FRAME_TARGET = "paddle-inline-checkout-frame";

const SUMMARY_EVENT_NAMES = new Set([
	CheckoutEventNames.CHECKOUT_LOADED,
	CheckoutEventNames.CHECKOUT_UPDATED,
	CheckoutEventNames.CHECKOUT_ITEMS_UPDATED,
	CheckoutEventNames.CHECKOUT_CUSTOMER_CREATED,
	CheckoutEventNames.CHECKOUT_CUSTOMER_UPDATED,
	CheckoutEventNames.CHECKOUT_DISCOUNT_APPLIED,
	CheckoutEventNames.CHECKOUT_DISCOUNT_REMOVED,
]);

/** Props for the `InlineCheckout` component. */
export type InlineCheckoutProps = {
	clientToken: string;
	environment?: Environments;
	items: CheckoutOpenLineItem[];

	variant?: "one-page" | "multi-page";
	theme?: "light" | "dark";
	locale?: string;
	/** Must be an absolute URL (starting with `https://` or `http://`) */
	successUrl?: string;
	/** Controls where the order summary appears relative to the checkout frame. Defaults to "start" (summary on the left). */
	summaryPosition?: "start" | "end" | "top" | "bottom";

	customer?: CheckoutCustomer;
	customerAuthToken?: string;
	discountCode?: string;
	discountId?: string;
	customData?: Record<string, unknown>;

	policyUrl?: string;
	policyLabel?: string;

	/** Called when the Paddle checkout completes successfully */
	onComplete?: (data: CheckoutCompleteData) => void;
	/** Called for every Paddle.js event emitted during checkout */
	onEvent?: (event: PaddleEventData) => void;
	/** Called when the Paddle checkout fails to initialize or encounters an error */
	onError?: (error: Error) => void;

	className?: string;
};

export function InlineCheckout({
	clientToken,
	environment = "production",
	items,
	variant = "one-page",
	theme,
	locale,
	successUrl,
	summaryPosition = "start",
	customer,
	customerAuthToken,
	discountCode,
	discountId,
	customData,
	policyUrl,
	policyLabel,
	onComplete,
	onEvent,
	onError,
	className,
}: InlineCheckoutProps) {
	const [summaryData, setSummaryData] = React.useState<CheckoutSummaryData | undefined>(undefined);
	const [initError, setInitError] = React.useState<Error | null>(null);

	// Ref avoids stale closure in event listener
	const onEventRef = React.useRef(onEvent);
	React.useEffect(() => {
		onEventRef.current = onEvent;
	}, [onEvent]);

	const { openCheckout, updateItems, isReady } = useCheckout({
		clientToken,
		environment,
		theme,
		locale,
		checkoutSettings: {
			displayMode: "inline",
			variant,
			frameTarget: INLINE_CHECKOUT_FRAME_TARGET,
			frameInitialHeight: 450,
			frameStyle: "width: 100%; min-width: 312px; background-color: transparent; border: none;",
		},
		onComplete,
		onError: (error) => {
			setInitError(error);
			onError?.(error);
		},
	});

	// Stable ref — effects re-run only when actual values change
	const stableCustomer = React.useMemo(
		() => customer,
		// eslint-disable-next-line react-hooks/exhaustive-deps
		[
			customer?.id,
			customer?.email,
			customer?.address?.id,
			customer?.address?.countryCode,
			customer?.address?.postalCode,
			customer?.address?.region,
			customer?.address?.city,
			customer?.address?.firstLine,
			customer?.business?.id,
			customer?.business?.name,
			customer?.business?.taxIdentifier,
		],
	);

	const stableCustomData = React.useMemo(
		() => customData,
		// eslint-disable-next-line react-hooks/exhaustive-deps
		[JSON.stringify(customData)],
	);

	const itemsKey = React.useMemo(
		() => items.map((i) => `${i.priceId}:${i.quantity ?? 1}`).join(","),
		[items],
	);

	const isOpenRef = React.useRef(false);
	// Tracks the last itemsKey applied to the open checkout so we can skip the
	// redundant updateItems call that would otherwise fire on the same render
	// cycle as openCheckout when isReady first becomes true.
	const prevItemsKeyRef = React.useRef<string | null>(null);

	// Open checkout once Paddle is ready
	React.useEffect(() => {
		if (!isReady || items.length === 0) return;

		if (!isOpenRef.current) {
			isOpenRef.current = true;
			openCheckout({
				priceId: items[0]!.priceId,
				items,
				...(stableCustomer && { customer: stableCustomer }),
				...(customerAuthToken && { customerAuthToken }),
				...(discountCode ? { discountCode } : discountId ? { discountId } : {}),
				...(stableCustomData && { customData: stableCustomData }),
				...(successUrl && { successUrl }),
			});
		}
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [isReady]);

	// Update items reactively after mount
	React.useEffect(() => {
		if (!(isReady && isOpenRef.current)) return;

		// First run after openCheckout — record the baseline key and skip the call.
		// openCheckout already applied these items; calling updateItems immediately
		// after would be a redundant SDK call.
		if (prevItemsKeyRef.current === null) {
			prevItemsKeyRef.current = itemsKey;
			return;
		}

		if (prevItemsKeyRef.current === itemsKey) return;
		prevItemsKeyRef.current = itemsKey;
		updateItems(items.map((i) => ({ priceId: i.priceId, quantity: i.quantity ?? 1 })));
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, [itemsKey, isReady]);

	// Subscribe to all Paddle events: update summary + forward to onEvent
	React.useEffect(() => {
		const unsubscribe = addPaddleEventListener((event: PaddleEventData) => {
			if (onEventRef.current) {
				onEventRef.current(event);
			}

			if (event.name && SUMMARY_EVENT_NAMES.has(event.name) && event.data) {
				setSummaryData(mapCheckoutEventsToSummary(event.data as CheckoutEventsData));
			}
		});

		return unsubscribe;
	}, []);

	if (initError) {
		return (
			<div
				className={cn(
					"rounded-lg border border-destructive/50 bg-destructive/10 p-4 text-sm text-destructive",
					className,
				)}
			>
				Failed to open checkout. Please refresh and try again.
			</div>
		);
	}

	const isHorizontal = summaryPosition === "start" || summaryPosition === "end";
	const summaryFirst = summaryPosition === "start" || summaryPosition === "top";

	return (
		<div
			className={cn(
				"flex gap-6",
				isHorizontal ? "flex-col lg:flex-row lg:items-start" : "flex-col",
				className,
			)}
		>
			{summaryFirst && (
				<div className={cn("w-full", isHorizontal && "lg:w-72 lg:shrink-0")}>
					<CheckoutSummary summary={summaryData} policyUrl={policyUrl} policyLabel={policyLabel} />
				</div>
			)}

			<div className="min-w-0 flex-1">
				<div className={cn(INLINE_CHECKOUT_FRAME_TARGET, "w-full min-h-[450px]")} />
			</div>

			{!summaryFirst && (
				<div className={cn("w-full", isHorizontal && "lg:w-72 lg:shrink-0")}>
					<CheckoutSummary summary={summaryData} policyUrl={policyUrl} policyLabel={policyLabel} />
				</div>
			)}
		</div>
	);
}
