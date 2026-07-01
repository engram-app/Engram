"use client";

import type {
	Environments,
	Paddle,
	PricePreviewParams,
	PricePreviewResponse,
} from "@paddle/paddle-js";
import { useCallback, useEffect, useRef, useState } from "react";
import { formatBillingCycle, formatTrialPeriod } from "@/lib/paddle-format";
import { getOrCreatePaddle } from "@/lib/paddle-instance";
import type { PriceData } from "@/lib/paddle-types";

export interface UsePaddlePricesArgs {
	clientToken: string;
	environment?: Environments;
	priceIds: string[];
	countryCode?: string;
	discountId?: string;
}

type PaddlePrices = Record<string, PriceData>;

function getPriceAmounts(prices: PricePreviewResponse): PaddlePrices {
	return prices.data.details.lineItems.reduce((acc, item) => {
		const hasDiscount = item.discounts.length > 0;
		acc[item.price.id] = {
			total: item.formattedTotals.total,
			originalTotal: hasDiscount ? item.formattedTotals.subtotal : undefined,
			interval: formatBillingCycle(item.price.billingCycle),
			trialPeriod: item.price.trialPeriod ? formatTrialPeriod(item.price.trialPeriod) : undefined,
		};
		return acc;
	}, {} as PaddlePrices);
}

export function usePaddlePrices(args: UsePaddlePricesArgs): {
	prices: PaddlePrices;
	loading: boolean;
	error: Error | null;
} {
	const { clientToken, environment = "production", priceIds, countryCode, discountId } = args;
	const [paddle, setPaddle] = useState<Paddle | null>(null);
	const [prices, setPrices] = useState<PaddlePrices>({});
	const [loading, setLoading] = useState<boolean>(true);
	const [error, setError] = useState<Error | null>(null);

	// Stable keys — prevent unnecessary re-fetches
	const priceIdsKey = priceIds.join(",");
	const discountIdKey = discountId ?? "";

	// Initialize Paddle once
	useEffect(() => {
		if (paddle || !clientToken) {
			return;
		}

		getOrCreatePaddle(clientToken, environment)
			.then((paddleInstance) => {
				if (paddleInstance) {
					setPaddle(paddleInstance);
				}
			})
			.catch((err) => {
				setError(err instanceof Error ? err : new Error("Failed to initialize Paddle"));
				setLoading(false);
			});
	}, [clientToken, environment, paddle]);

	// Fetch prices when Paddle is ready or inputs change
	const fetchedRef = useRef<string | null>(null);

	const fetchPrices = useCallback(async () => {
		if (!paddle) {
			return;
		}

		const fetchKey = `${priceIdsKey}:${countryCode ?? ""}:${discountIdKey}`;
		if (fetchedRef.current === fetchKey) {
			return;
		}
		fetchedRef.current = fetchKey;

		const priceIdList = priceIdsKey.split(",").filter(Boolean);
		if (priceIdList.length === 0) {
			return;
		}

		const paddlePricePreviewRequest: Partial<PricePreviewParams> = {
			items: priceIdList.map((priceId) => ({ priceId, quantity: 1 })),
			...(countryCode && { address: { countryCode } }),
			...(discountId && { discountId }),
		};

		setLoading(true);

		try {
			const priceResponse = await paddle.PricePreview(
				paddlePricePreviewRequest as PricePreviewParams,
			);
			setPrices(getPriceAmounts(priceResponse));
			setError(null);
		} catch (err) {
			setError(err instanceof Error ? err : new Error("Failed to fetch prices"));
		} finally {
			setLoading(false);
		}
	}, [paddle, priceIdsKey, countryCode, discountIdKey]);

	useEffect(() => {
		fetchPrices();
	}, [fetchPrices]);

	return { prices, loading, error };
}
