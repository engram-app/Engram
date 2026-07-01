"use client";

import {
	AlertCircle,
	CalendarIcon,
	CheckCircle2,
	Clock,
	CreditCardIcon,
	FileTextIcon,
	MinusCircle,
	PauseCircle,
	Sparkles,
} from "lucide-react";
import type * as React from "react";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { Skeleton } from "@/components/ui/skeleton";
import { formatBillingCycle, formatDate, formatMoney } from "@/lib/paddle-format";
import type { SubscriptionStatusData } from "@/lib/paddle-types";
import { cn } from "@/lib/utils";

export interface SubscriptionStatusCardProps {
	subscription?: SubscriptionStatusData;
	/** Override the card title. Defaults to the first item's product name (single-item) or "Subscription" (multi-item). */
	title?: string;
	/** Position of the status badge: "inline" next to name, or "end" aligned to card end */
	statusBadgePosition?: "inline" | "end";
	/**
	 * Called when the user clicks "Change plan".
	 * Only rendered when status is not `paused` or `canceled` — paused
	 * subscriptions must be resumed before items can be changed, and canceled
	 * is a terminal state.
	 */
	onChangePlan?: () => void;
	/**
	 * Called when the user clicks "Update payment method".
	 * Only rendered for automatically-collected subscriptions that are not
	 * `paused` or `canceled` — manual subscriptions are invoice-based (no saved
	 * payment method), paused subscriptions have no active billing, and canceled
	 * is terminal.
	 */
	onUpdatePaymentMethod?: () => void;
	/**
	 * Called when the user clicks "Manage". Always rendered when provided —
	 * the action is consumer-defined (portal link, modal, resubscribe flow, etc.)
	 * and not restricted by Paddle subscription status.
	 */
	onManageSubscription?: () => void;
	className?: string;
}

// --- Status badge ---

type SubscriptionStatus = "active" | "canceled" | "past_due" | "paused" | "trialing";

const STATUS_CONFIG: Record<
	SubscriptionStatus,
	{ label: string; icon: React.ElementType; className: string }
> = {
	active: {
		label: "Active",
		icon: CheckCircle2,
		className: "bg-success/15 text-success-foreground border-success/30",
	},
	trialing: {
		label: "Trial",
		icon: Sparkles,
		className: "bg-info/15 text-info-foreground border-info/30",
	},
	past_due: {
		label: "Past due",
		icon: AlertCircle,
		className: "bg-destructive/15 text-destructive border-destructive/30",
	},
	paused: {
		label: "Paused",
		icon: PauseCircle,
		className: "bg-warning/15 text-warning-foreground border-warning/30",
	},
	canceled: {
		label: "Canceled",
		icon: MinusCircle,
		className: "bg-muted text-muted-foreground border-border",
	},
};

function StatusBadge({ status }: { status: SubscriptionStatus }) {
	const config = STATUS_CONFIG[status] ?? {
		label: status.replace(/_/gu, " ").replace(/\b\w/gu, (c) => c.toUpperCase()),
		icon: AlertCircle,
		className: "bg-muted text-muted-foreground border-border",
	};
	const Icon = config.icon;
	return (
		<Badge variant="outline" className={cn("gap-1 font-medium", config.className)}>
			<Icon className="size-3" />
			{config.label}
		</Badge>
	);
}

// --- Scheduled change validity ---

/**
 * Returns the scheduledChange only when it is valid for the given status.
 * Impossible combinations (e.g. resume on active, cancel on paused, any
 * scheduled change on canceled) are suppressed so the component never
 * renders misleading alerts.
 */
function getValidScheduledChange(
	status: SubscriptionStatus,
	scheduledChange?: SubscriptionStatusData["scheduledChange"],
): SubscriptionStatusData["scheduledChange"] | undefined {
	if (!scheduledChange) {
		return;
	}
	switch (status) {
		case "canceled":
			return;
		case "paused":
			return scheduledChange.action === "resume" ? scheduledChange : undefined;
		default:
			return scheduledChange.action === "resume" ? undefined : scheduledChange;
	}
}

// --- Footer billing label ---

function getNextBillingLabel(
	status: SubscriptionStatus,
	scheduledChange?: SubscriptionStatusData["scheduledChange"],
): string | undefined {
	if (scheduledChange?.action === "cancel" || scheduledChange?.action === "pause") {
		return;
	}
	switch (status) {
		case "trialing":
			return "First billing";
		case "past_due":
			return "Payment due";
		case "active":
			return "Next billing";
		default:
			return;
	}
}

// --- Button visibility rules ---

/**
 * "Change plan" is available for active, trialing, and past_due subscriptions.
 * Paused subscriptions must be resumed before items can be changed.
 * Canceled is a terminal state.
 */
function canShowChangePlan(status: SubscriptionStatus): boolean {
	return status !== "paused" && status !== "canceled";
}

/**
 * "Update payment method" requires automatic collection and an active billing
 * relationship. Manual subscriptions are invoice-based — no saved payment
 * method exists. Paused subscriptions have no active billing. Canceled is
 * terminal.
 */
function canShowUpdatePaymentMethod(
	status: SubscriptionStatus,
	collectionMode?: "automatic" | "manual",
): boolean {
	return status !== "canceled" && status !== "paused" && collectionMode !== "manual";
}

// --- Main component ---

export function SubscriptionStatusCard({
	subscription,
	title: titleOverride,
	statusBadgePosition = "end",
	onChangePlan,
	onUpdatePaymentMethod,
	onManageSubscription,
	className,
}: SubscriptionStatusCardProps) {
	if (!subscription) {
		return <SubscriptionStatusCardSkeleton className={className} />;
	}

	const {
		items,
		totalAmount,
		currency,
		interval,
		billingFrequency,
		status,
		nextBilledAt,
		canceledAt,
		collectionMode,
		scheduledChange,
		discount,
	} = subscription;

	const isSingleItem = items.length === 1;
	const [primaryItem] = items;
	const isPastDue = status === "past_due";

	const effectiveScheduledChange = getValidScheduledChange(status, scheduledChange);

	const showChangePlan = Boolean(onChangePlan) && canShowChangePlan(status);
	const showUpdatePayment =
		Boolean(onUpdatePaymentMethod) && canShowUpdatePaymentMethod(status, collectionMode);
	const showManage = Boolean(onManageSubscription);
	const hasActions = showChangePlan || showUpdatePayment || showManage;

	const cardTitle =
		titleOverride ?? (isSingleItem ? primaryItem?.productName : undefined) ?? "Subscription";

	const billingIntervalLabel =
		formatBillingCycle({ interval, frequency: billingFrequency ?? 1 }) ?? interval;

	const scheduledChangeNote = effectiveScheduledChange
		? effectiveScheduledChange.action === "cancel"
			? `Cancels on ${formatDate(effectiveScheduledChange.effectiveAt)}`
			: effectiveScheduledChange.action === "pause"
				? `Pauses on ${formatDate(effectiveScheduledChange.effectiveAt)}`
				: effectiveScheduledChange.action === "resume"
					? `Resumes on ${formatDate(effectiveScheduledChange.effectiveAt)}`
					: undefined
		: undefined;

	const nextBillingLabel = getNextBillingLabel(status, effectiveScheduledChange);

	return (
		<Card
			className={cn("gap-4", className)}
			data-status={status}
			data-past-due={isPastDue || undefined}
		>
			<CardHeader>
				<div className="flex items-start justify-between gap-4">
					<div className="min-w-0 flex-1 space-y-1">
						<div className="flex flex-wrap items-center gap-2">
							<CardTitle className="truncate">{cardTitle}</CardTitle>
							{statusBadgePosition === "inline" && <StatusBadge status={status} />}
						</div>
						{isSingleItem && primaryItem?.priceName ? (
							<CardDescription>{primaryItem.priceName}</CardDescription>
						) : null}
					</div>
					<div className="flex shrink-0 items-center gap-2">
						{statusBadgePosition === "end" && <StatusBadge status={status} />}
						{isSingleItem && primaryItem?.productImageUrl ? (
							<img
								src={primaryItem.productImageUrl}
								alt={primaryItem.productName}
								className="size-12 rounded-md object-cover"
							/>
						) : null}
					</div>
				</div>
			</CardHeader>

			<CardContent className="space-y-3">
				{isPastDue && (
					<Alert variant="destructive">
						<AlertCircle className="size-4" />
						<AlertTitle>
							{collectionMode === "manual" ? "Invoice overdue" : "Payment required"}
						</AlertTitle>
						<AlertDescription>
							{collectionMode === "manual"
								? "Pay your outstanding invoice to avoid disruption."
								: "Your subscription is past due. Update your payment method to avoid disruption."}
						</AlertDescription>
					</Alert>
				)}

				{Boolean(scheduledChangeNote) && (
					<Alert>
						<Clock className="size-4" />
						<AlertTitle>Scheduled change</AlertTitle>
						<AlertDescription>{scheduledChangeNote}</AlertDescription>
					</Alert>
				)}

				<div className="space-y-2">
					{items.map((item, index) => (
						<div
							key={`${item.productName}-${item.priceName ?? ""}`}
							className={cn(
								"flex items-center justify-between gap-4",
								index > 0 && "border-t pt-2",
							)}
						>
							<div className="flex min-w-0 items-center gap-2">
								{item.productImageUrl && items.length > 1 && (
									<img
										src={item.productImageUrl}
										alt={item.productName}
										className="size-6 shrink-0 rounded object-cover"
									/>
								)}
								<div className="min-w-0 space-y-0.5">
									<p className="truncate font-medium text-sm">{item.productName}</p>
									{item.quantity > 1 && item.unitPrice !== undefined && (
										<p className="text-muted-foreground text-sm">
											{item.quantity} &times; {formatMoney(item.unitPrice, currency)}
										</p>
									)}
								</div>
							</div>
							<p className="shrink-0 font-medium text-sm tabular-nums">
								{formatMoney(item.lineTotal, currency)}
							</p>
						</div>
					))}
				</div>

				<Separator />

				<div className="space-y-1.5">
					{discount ? (
						<div className="flex items-center justify-between text-success-foreground">
							<span className="flex items-center gap-1.5 text-sm">
								Discount
								{Boolean(discount.code) && (
									<span className="rounded bg-success/10 px-1.5 py-0.5 text-xs">
										{discount.code}
									</span>
								)}
								{discount.endsAt ? (
									<span className="text-muted-foreground text-xs">
										until {formatDate(discount.endsAt)}
									</span>
								) : null}
							</span>
							<span className="text-sm tabular-nums">
								{discount.description ?? `\u2212${formatMoney(discount.savingsAmount, currency)}`}
							</span>
						</div>
					) : null}

					<div className="flex items-center justify-between font-medium">
						<span className="text-sm">Total</span>
						<span className="text-sm tabular-nums">
							{formatMoney(totalAmount, currency)}
							<span className="font-normal text-muted-foreground"> / {billingIntervalLabel}</span>
						</span>
					</div>
				</div>

				<Separator />

				<div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-muted-foreground text-sm">
					{nextBilledAt && nextBillingLabel ? (
						<div className="flex items-center gap-1.5">
							<CalendarIcon className="size-3.5" />
							<span>
								{nextBillingLabel} {formatDate(nextBilledAt)}
							</span>
						</div>
					) : null}
					{collectionMode && !effectiveScheduledChange && status !== "past_due" && (
						<div className="flex items-center gap-1.5">
							{collectionMode === "automatic" ? (
								<>
									<CreditCardIcon className="size-3.5" />
									<span>Auto-renews</span>
								</>
							) : (
								<>
									<FileTextIcon className="size-3.5" />
									<span>Invoiced</span>
								</>
							)}
						</div>
					)}
					{canceledAt ? (
						<div className="flex items-center gap-1.5">
							<span>Canceled {formatDate(canceledAt)}</span>
						</div>
					) : null}
				</div>

				{Boolean(hasActions) && (
					<div className="flex flex-wrap gap-2 pt-1">
						{Boolean(showChangePlan) && (
							<Button onClick={onChangePlan} size="sm">
								Change plan
							</Button>
						)}
						{Boolean(showUpdatePayment) && (
							<Button
								variant={isPastDue ? "default" : "outline"}
								size="sm"
								onClick={onUpdatePaymentMethod}
							>
								Update payment method
							</Button>
						)}
						{showManage && (
							<Button variant="outline" size="sm" onClick={onManageSubscription}>
								Manage
							</Button>
						)}
					</div>
				)}
			</CardContent>
		</Card>
	);
}

function SubscriptionStatusCardSkeleton({ className }: { className?: string }) {
	return (
		<Card className={cn("gap-4", className)}>
			<CardHeader>
				<div className="flex items-start justify-between gap-4">
					<div className="flex-1 space-y-2">
						<div className="flex items-center gap-2">
							<Skeleton className="h-6 w-32" />
							<Skeleton className="h-5 w-16" />
						</div>
						<Skeleton className="h-4 w-20" />
					</div>
					<Skeleton className="size-12 rounded-md" />
				</div>
			</CardHeader>
			<CardContent className="space-y-3">
				<div className="space-y-2">
					<div className="flex items-center justify-between">
						<div className="space-y-1">
							<Skeleton className="h-4 w-24" />
							<Skeleton className="h-4 w-16" />
						</div>
						<Skeleton className="h-4 w-16" />
					</div>
				</div>
				<Separator />
				<div className="space-y-1.5">
					<div className="flex items-center justify-between">
						<Skeleton className="h-4 w-12" />
						<Skeleton className="h-4 w-20" />
					</div>
				</div>
				<Separator />
				<div className="flex items-center gap-4">
					<Skeleton className="h-4 w-28" />
					<Skeleton className="h-4 w-20" />
				</div>
				<div className="flex gap-2 pt-1">
					<Skeleton className="h-8 w-24" />
					<Skeleton className="h-8 w-20" />
				</div>
			</CardContent>
		</Card>
	);
}
