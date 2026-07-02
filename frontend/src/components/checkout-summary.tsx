"use client";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { Skeleton } from "@/components/ui/skeleton";
import { formatBillingCycle, formatMoney } from "@/lib/paddle-format";
import type { CheckoutSummaryData } from "@/lib/paddle-types";
import { cn } from "@/lib/utils";

function CheckoutSummarySkeleton({ className }: { className?: string }) {
	return (
		<Card className={cn("gap-4", className)}>
			<CardHeader>
				<Skeleton className="h-4 w-28" />
			</CardHeader>
			<CardContent className="flex flex-col gap-4">
				<div className="space-y-3">
					<div className="flex justify-between gap-4">
						<Skeleton className="h-4 w-36" />
						<Skeleton className="h-4 w-16" />
					</div>
					<div className="flex justify-between gap-4">
						<Skeleton className="h-4 w-28" />
						<Skeleton className="h-4 w-16" />
					</div>
				</div>
				<Separator />
				<div className="space-y-2">
					<div className="flex justify-between gap-4">
						<Skeleton className="h-4 w-16" />
						<Skeleton className="h-4 w-14" />
					</div>
					<div className="flex justify-between gap-4">
						<Skeleton className="h-4 w-8" />
						<Skeleton className="h-4 w-14" />
					</div>
					<Separator />
					<div className="flex justify-between gap-4">
						<Skeleton className="h-4 w-10" />
						<Skeleton className="h-4 w-16" />
					</div>
				</div>
				<Skeleton className="h-3 w-48" />
			</CardContent>
		</Card>
	);
}

/** Props for the `CheckoutSummary` component. */
export interface CheckoutSummaryProps {
	summary?: CheckoutSummaryData;
	policyUrl?: string;
	policyLabel?: string;
	className?: string;
}

export function CheckoutSummary({
	summary,
	policyUrl,
	policyLabel = "Refund policy",
	className,
}: CheckoutSummaryProps) {
	if (!summary) {
		return <CheckoutSummarySkeleton className={className} />;
	}

	const {
		items,
		subtotal,
		tax,
		total,
		discount,
		currency,
		recurringTotal,
		recurringInterval,
		recurringFrequency,
		trialPeriod,
	} = summary;

	const recurringInfo =
		recurringTotal !== undefined && recurringInterval
			? (() => {
					const cycleLabel = formatBillingCycle({
						frequency: recurringFrequency ?? 1,
						interval: recurringInterval,
					});
					const recurringAmount = formatMoney(recurringTotal, currency);
					return cycleLabel ? `${recurringAmount} / ${cycleLabel}` : recurringAmount;
				})()
			: undefined;

	return (
		<Card className={cn("gap-4", className)}>
			<CardHeader>
				<CardTitle className="font-semibold text-base">Order summary</CardTitle>
			</CardHeader>

			<CardContent className="flex flex-col gap-4">
				<ul className="space-y-3">
					{items.map((item) => (
						<li
							key={`${item.name}-${item.priceName ?? ""}`}
							className="flex items-start justify-between gap-4 text-sm"
						>
							<div className="min-w-0 flex-1">
								<span className="font-medium">{item.name}</span>
								{Boolean(item.priceName) && (
									<span className="text-muted-foreground"> — {item.priceName}</span>
								)}
								{item.quantity > 1 && (
									<span className="text-muted-foreground"> × {item.quantity}</span>
								)}
							</div>
							<span className="shrink-0 tabular-nums">{formatMoney(item.lineTotal, currency)}</span>
						</li>
					))}
				</ul>

				<Separator />

				<dl className="space-y-2 text-sm">
					<div className="flex justify-between">
						<dt className="text-muted-foreground">Subtotal</dt>
						<dd className="tabular-nums">{formatMoney(subtotal, currency)}</dd>
					</div>

					{discount != null && discount > 0 && (
						<div className="flex justify-between text-success-foreground">
							<dt>Discount</dt>
							<dd className="tabular-nums">−{formatMoney(discount, currency)}</dd>
						</div>
					)}

					<div className="flex justify-between">
						<dt className="text-muted-foreground">Tax</dt>
						<dd className="tabular-nums">{formatMoney(tax, currency)}</dd>
					</div>

					<Separator />

					<div className="flex justify-between font-semibold">
						<dt>Total</dt>
						<dd className="tabular-nums">{formatMoney(total, currency)}</dd>
					</div>
				</dl>

				{Boolean(recurringInfo || trialPeriod) && (
					<p className="text-muted-foreground text-xs">
						{Boolean(trialPeriod) && <span>{trialPeriod} free trial. </span>}
						{Boolean(recurringInfo) && <span>Then {recurringInfo}.</span>}
					</p>
				)}

				{Boolean(policyUrl) && (
					<a
						href={policyUrl}
						target="_blank"
						rel="noopener noreferrer"
						className="text-muted-foreground text-xs underline transition-colors hover:text-foreground"
					>
						{policyLabel}
					</a>
				)}
			</CardContent>
		</Card>
	);
}
