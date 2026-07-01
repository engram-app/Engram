"use client";

import { AlertCircle, ArrowRight } from "lucide-react";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { Skeleton } from "@/components/ui/skeleton";
import {
	formatBillingCycle,
	formatDate,
	formatMoney,
	formatProrationMode,
} from "@/lib/paddle-format";
import type { PlanChangePreviewData } from "@/lib/paddle-types";
import { cn } from "@/lib/utils";

/** Props for the `PlanChangePreview` component. */
export interface PlanChangePreviewProps {
	preview?: PlanChangePreviewData;
	/**
	 * Paddle proration billing mode passed to `PATCH /subscriptions/{id}/preview`.
	 * The component derives the billing row label and effective date from this value.
	 */
	prorationBillingMode?:
		| "prorated_immediately"
		| "full_immediately"
		| "prorated_next_billing_period"
		| "full_next_billing_period"
		| "do_not_bill";
	className?: string;
}

export function PlanChangePreview({
	preview,
	prorationBillingMode,
	className,
}: PlanChangePreviewProps) {
	if (!preview) {
		return <PlanChangePreviewSkeleton className={className} />;
	}

	const {
		currency,
		currentPlan,
		newPlan,
		costImpact,
		discount,
		scheduledChange,
		subscriptionStatus,
		collectionMode,
	} = preview;
	const isCharge = costImpact.resultDirection === "charge";
	const isCredit = costImpact.resultDirection === "credit";
	const isNeutral = costImpact.resultDirection === "none";
	const isManual = collectionMode === "manual";
	const isTrialing = subscriptionStatus === "trialing";

	const changeType = isCharge ? "upgrade" : isCredit ? "downgrade" : "change";

	const prorationLabel = prorationBillingMode
		? formatProrationMode(prorationBillingMode)
		: undefined;

	const isImmediate =
		prorationBillingMode?.includes("immediately") || prorationBillingMode === "do_not_bill";

	function resolveEffectiveDate(): string | undefined {
		if (prorationBillingMode) {
			if (isImmediate) {
				return "Immediately";
			}
			return costImpact.nextBillDate ? formatDate(costImpact.nextBillDate) : undefined;
		}
		if (costImpact.immediateAmount !== undefined) {
			return "Immediately";
		}
		return costImpact.nextBillDate ? formatDate(costImpact.nextBillDate) : undefined;
	}
	const effectiveDate = resolveEffectiveDate();

	function resolveScheduledChangeMessage(): string | undefined {
		if (!scheduledChange) {
			return;
		}
		if (scheduledChange.action === "resume") {
			return;
		}
		const actionLabel = scheduledChange.action === "cancel" ? "Cancellation" : "Pause";
		return `${actionLabel} scheduled for ${formatDate(scheduledChange.effectiveAt)}. Billing options may be restricted.`;
	}
	const scheduledChangeMessage = resolveScheduledChangeMessage();

	const hasBreakdownRows = costImpact.credit !== undefined || costImpact.charge !== undefined;

	const totalLabel = isCredit
		? "Credit to account"
		: isNeutral
			? "No charge"
			: isManual
				? "Invoice amount"
				: costImpact.immediateAmount === undefined
					? "Amount at next billing"
					: "Amount due now";

	const currentIntervalLabel =
		formatBillingCycle({
			interval: currentPlan.interval,
			frequency: currentPlan.billingFrequency ?? 1,
		}) ?? currentPlan.interval;

	const newIntervalLabel =
		formatBillingCycle({
			interval: newPlan.interval,
			frequency: newPlan.billingFrequency ?? 1,
		}) ?? newPlan.interval;

	return (
		<Card className={cn("gap-4", className)}>
			<CardHeader>
				<CardTitle className="font-semibold text-base">Change summary</CardTitle>
				<CardDescription>Review the overview of this change</CardDescription>
			</CardHeader>

			<CardContent className="space-y-4">
				{scheduledChangeMessage && (
					<Alert>
						<AlertCircle className="size-4" />
						<AlertDescription>{scheduledChangeMessage}</AlertDescription>
					</Alert>
				)}

				<div className="flex items-stretch gap-3">
					<div className="min-w-0 flex-1 rounded-lg border bg-muted/40 p-3">
						<div className="mb-1 text-muted-foreground text-xs">Current plan</div>
						<div className="truncate font-medium text-sm">{currentPlan.productName}</div>
						<div className="text-muted-foreground text-sm">
							{formatMoney(currentPlan.price, currency)}
							<span className="text-xs"> / {currentIntervalLabel}</span>
						</div>
					</div>

					<div className="flex shrink-0 items-center">
						<ArrowRight className="size-4 text-muted-foreground" />
					</div>

					<div className="min-w-0 flex-1 rounded-lg border border-primary/20 bg-primary/5 p-3">
						<div className="mb-1 text-muted-foreground text-xs">New plan</div>
						<div className="truncate font-medium text-sm">{newPlan.productName}</div>
						<div className="text-muted-foreground text-sm">
							{formatMoney(newPlan.price, currency)}
							<span className="text-xs"> / {newIntervalLabel}</span>
						</div>
					</div>
				</div>

				<Separator />

				<div className="space-y-2">
					<div className="flex items-center justify-between text-sm">
						<span className="text-muted-foreground">Change type</span>
						<Badge
							variant={
								changeType === "upgrade"
									? "default"
									: changeType === "downgrade"
										? "secondary"
										: "outline"
							}
						>
							{changeType === "upgrade"
								? "Upgrade"
								: changeType === "downgrade"
									? "Downgrade"
									: "Change"}
						</Badge>
					</div>

					{Boolean(prorationLabel) && (
						<div className="flex items-center justify-between text-sm">
							<span className="text-muted-foreground">Billing</span>
							<span className="text-right">{prorationLabel}</span>
						</div>
					)}

					{effectiveDate && (
						<div className="flex items-center justify-between text-sm">
							<span className="text-muted-foreground">Effective</span>
							<span>{effectiveDate}</span>
						</div>
					)}

					{discount ? (
						<div className="flex items-center justify-between text-sm">
							<span className="text-muted-foreground">Discount</span>
							<span className="text-right">
								<span className="text-success-foreground">{discount.description}</span>
								{discount.endsAt ? (
									<span className="block text-muted-foreground text-xs">
										until {formatDate(discount.endsAt)}
									</span>
								) : null}
							</span>
						</div>
					) : null}
				</div>

				<Separator />

				<div className="space-y-1.5">
					<div className="flex items-center justify-between text-sm">
						<span className="text-muted-foreground">Current</span>
						<span>
							{formatMoney(currentPlan.price, currency)}
							<span className="text-muted-foreground text-xs"> / {currentIntervalLabel}</span>
						</span>
					</div>
					<div className="flex items-center justify-between text-sm">
						<span className="text-muted-foreground">New</span>
						<span>
							{formatMoney(newPlan.price, currency)}
							<span className="text-muted-foreground text-xs"> / {newIntervalLabel}</span>
						</span>
					</div>
				</div>

				{/* Financial summary — credit/charge breakdown + total row */}
				{(hasBreakdownRows || !isNeutral) && (
					<>
						<Separator />
						<div className="space-y-1.5">
							{costImpact.credit !== undefined && (
								<div className="flex items-center justify-between text-sm text-success-foreground">
									<span>Credit</span>
									<span>−{formatMoney(costImpact.credit, currency)}</span>
								</div>
							)}
							{costImpact.charge !== undefined && (
								<div className="flex items-center justify-between text-sm">
									<span className="text-muted-foreground">Charge</span>
									<span>{formatMoney(costImpact.charge, currency)}</span>
								</div>
							)}
							<div
								className={cn(
									"flex items-center justify-between font-medium",
									hasBreakdownRows && "border-t pt-1.5",
								)}
							>
								<span>{totalLabel}</span>
								<span className={cn(isCredit && "text-success-foreground")}>
									{isCredit ? "−" : ""}
									{formatMoney(costImpact.resultAmount, currency)}
								</span>
							</div>
						</div>
					</>
				)}

				{/* Contextual notes derived from subscription state */}
				{Boolean(isTrialing && isNeutral) && (
					<p className="text-muted-foreground text-xs">
						No charges during your trial. Billing begins when your trial ends.
					</p>
				)}
				{Boolean(isManual && isCharge) && (
					<p className="text-muted-foreground text-xs">
						An invoice will be created for this amount.
					</p>
				)}
			</CardContent>
		</Card>
	);
}

function PlanChangePreviewSkeleton({ className }: { className?: string }) {
	return (
		<Card className={cn("gap-4", className)}>
			<CardHeader>
				<Skeleton className="h-4 w-40" />
				<Skeleton className="h-3 w-52" />
			</CardHeader>
			<CardContent className="space-y-4">
				<div className="flex items-stretch gap-3">
					<div className="flex-1 space-y-2 rounded-lg border bg-muted/40 p-3">
						<Skeleton className="h-3 w-20" />
						<Skeleton className="h-4 w-24" />
						<Skeleton className="h-3 w-16" />
					</div>
					<div className="flex items-center">
						<Skeleton className="h-4 w-4 rounded" />
					</div>
					<div className="flex-1 space-y-2 rounded-lg border p-3">
						<Skeleton className="h-3 w-16" />
						<Skeleton className="h-4 w-20" />
						<Skeleton className="h-3 w-16" />
					</div>
				</div>
				<Separator />
				<div className="space-y-2">
					<div className="flex justify-between">
						<Skeleton className="h-4 w-20" />
						<Skeleton className="h-5 w-16" />
					</div>
					<div className="flex justify-between">
						<Skeleton className="h-4 w-16" />
						<Skeleton className="h-4 w-32" />
					</div>
				</div>
				<Separator />
				<div className="space-y-1.5">
					<div className="flex justify-between">
						<Skeleton className="h-4 w-16" />
						<Skeleton className="h-4 w-20" />
					</div>
					<div className="flex justify-between">
						<Skeleton className="h-4 w-8" />
						<Skeleton className="h-4 w-20" />
					</div>
				</div>
			</CardContent>
		</Card>
	);
}
