"use client";

import { Calendar, CreditCard, ExternalLink } from "lucide-react";
import type * as React from "react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Separator } from "@/components/ui/separator";
import { Skeleton } from "@/components/ui/skeleton";
import { formatDate, formatMoney } from "@/lib/paddle-format";
import { getPaymentMethodDisplay } from "@/lib/paddle-payment-method-display";
import type { NextPaymentData, PaymentMethodData } from "@/lib/paddle-types";
import { getPaymentMethodIcon } from "@/lib/payment-method-icons";
import { cn } from "@/lib/utils";

function PaymentInfoRow({
	icon: Icon,
	label,
	children,
}: {
	icon: React.ElementType;
	label: string;
	children: React.ReactNode;
}) {
	return (
		<div className="flex items-start gap-3">
			<div className="flex size-8 shrink-0 items-center justify-center rounded-md bg-muted">
				<Icon className="size-4 text-muted-foreground" />
			</div>
			<div className="min-w-0">
				<div className="text-muted-foreground text-sm">{label}</div>
				{children}
			</div>
		</div>
	);
}

function SubscriptionPaymentCardSkeleton({ className }: { className?: string }) {
	return (
		<Card className={cn("gap-4", className)}>
			<CardHeader>
				<Skeleton className="h-4 w-20" />
			</CardHeader>
			<CardContent className="flex flex-col gap-4">
				<div className="flex items-start gap-3">
					<Skeleton className="size-8 shrink-0 rounded-md" />
					<div className="space-y-1.5">
						<Skeleton className="h-3 w-24" />
						<Skeleton className="h-5 w-16" />
						<Skeleton className="h-3 w-20" />
					</div>
				</div>
				<Separator />
				<div className="flex items-center justify-between gap-4">
					<div className="flex items-center gap-3">
						<Skeleton className="size-8 shrink-0 rounded-md" />
						<div className="space-y-1.5">
							<Skeleton className="h-3 w-28" />
							<Skeleton className="h-4 w-20" />
						</div>
					</div>
					<Skeleton className="h-4 w-14" />
				</div>
			</CardContent>
		</Card>
	);
}

export interface SubscriptionPaymentCardProps {
	/**
	 * Next payment details. Absent when subscription is paused or canceled.
	 *
	 * Pass `undefined` for all three data props (`nextPayment`, `paymentMethod`,
	 * `updatePaymentMethodUrl`) to render the skeleton loading state.
	 */
	nextPayment?: NextPaymentData;
	/**
	 * Payment method details. Pass raw fields from `transaction.payments[0].method_details`
	 * — the component resolves the display label automatically.
	 * Absent when not available from transaction history.
	 */
	paymentMethod?: PaymentMethodData;
	/** Portal deep link to update payment method. Absent for manual collection. */
	updatePaymentMethodUrl?: string;
	className?: string;
}

export function SubscriptionPaymentCard({
	nextPayment,
	paymentMethod,
	updatePaymentMethodUrl,
	className,
}: SubscriptionPaymentCardProps) {
	const isLoading =
		nextPayment === undefined &&
		paymentMethod === undefined &&
		updatePaymentMethodUrl === undefined;

	if (isLoading) {
		return <SubscriptionPaymentCardSkeleton className={className} />;
	}

	const displayLabel = paymentMethod
		? (paymentMethod.label ??
			getPaymentMethodDisplay(paymentMethod.type, paymentMethod.cardBrand, paymentMethod.last4))
		: undefined;

	const PaymentMethodIcon = paymentMethod
		? (getPaymentMethodIcon(paymentMethod.type, paymentMethod.cardBrand) ?? CreditCard)
		: CreditCard;

	const expiryLabel =
		paymentMethod?.expiryMonth !== undefined && paymentMethod?.expiryYear !== undefined
			? `Expires ${String(paymentMethod.expiryMonth).padStart(2, "0")}/${String(paymentMethod.expiryYear).slice(-2)}`
			: undefined;

	return (
		<Card className={cn("gap-4", className)}>
			<CardHeader>
				<CardTitle className="font-semibold text-base">Payment</CardTitle>
			</CardHeader>

			<CardContent className="flex flex-col gap-4">
				<PaymentInfoRow icon={Calendar} label="Next payment">
					{nextPayment ? (
						<>
							<div className="font-semibold">
								{formatMoney(nextPayment.amount, nextPayment.currency)}
							</div>
							<div className="text-muted-foreground text-sm">{formatDate(nextPayment.date)}</div>
						</>
					) : (
						<div className="font-medium text-muted-foreground text-sm">No upcoming payment</div>
					)}
				</PaymentInfoRow>

				{Boolean(displayLabel) && (
					<>
						<Separator />
						<div className="flex items-center justify-between gap-4">
							<PaymentInfoRow icon={PaymentMethodIcon} label="Payment method">
								<div className="truncate font-medium text-sm">{displayLabel}</div>
								{Boolean(expiryLabel) && (
									<div className="text-muted-foreground text-xs">{expiryLabel}</div>
								)}
							</PaymentInfoRow>

							{Boolean(updatePaymentMethodUrl) && (
								<a
									href={updatePaymentMethodUrl}
									target="_blank"
									rel="noopener noreferrer"
									className="flex shrink-0 items-center gap-1 font-medium text-primary text-sm hover:underline"
								>
									Update
									<ExternalLink className="size-3" />
								</a>
							)}
						</div>
					</>
				)}

				{/* Update link when no payment method but URL is available */}
				{!displayLabel && updatePaymentMethodUrl && (
					<>
						<Separator />
						<a
							href={updatePaymentMethodUrl}
							target="_blank"
							rel="noopener noreferrer"
							className="flex items-center gap-1 font-medium text-primary text-sm hover:underline"
						>
							<CreditCard className="size-4" />
							Update payment method
							<ExternalLink className="ml-0.5 size-3" />
						</a>
					</>
				)}
			</CardContent>
		</Card>
	);
}
