"use client";

import * as React from "react";
import { CreditCard, Calendar, ExternalLink } from "lucide-react";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { Separator } from "@/components/ui/separator";
import { cn } from "@/lib/utils";
import type { NextPaymentData, PaymentMethodData } from "@/lib/paddle-types";
import { getPaymentMethodDisplay } from "@/lib/paddle-payment-method-display";
import { getPaymentMethodIcon } from "@/lib/payment-method-icons";
import { formatMoney, formatDate } from "@/lib/paddle-format";

export type SubscriptionPaymentCardProps = {
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
};

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
				<CardTitle className="text-base font-semibold">Payment</CardTitle>
			</CardHeader>

			<CardContent className="flex flex-col gap-4">
				<PaymentInfoRow icon={Calendar} label="Next payment">
					{nextPayment ? (
						<>
							<div className="font-semibold">
								{formatMoney(nextPayment.amount, nextPayment.currency)}
							</div>
							<div className="text-sm text-muted-foreground">{formatDate(nextPayment.date)}</div>
						</>
					) : (
						<div className="text-sm font-medium text-muted-foreground">No upcoming payment</div>
					)}
				</PaymentInfoRow>

				{displayLabel && (
					<>
						<Separator />
						<div className="flex items-center justify-between gap-4">
							<PaymentInfoRow icon={PaymentMethodIcon} label="Payment method">
								<div className="text-sm font-medium truncate">{displayLabel}</div>
								{expiryLabel && <div className="text-xs text-muted-foreground">{expiryLabel}</div>}
							</PaymentInfoRow>

							{updatePaymentMethodUrl && (
								<a
									href={updatePaymentMethodUrl}
									target="_blank"
									rel="noopener noreferrer"
									className="flex items-center gap-1 text-sm font-medium text-primary hover:underline shrink-0"
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
							className="flex items-center gap-1 text-sm font-medium text-primary hover:underline"
						>
							<CreditCard className="size-4" />
							Update payment method
							<ExternalLink className="size-3 ml-0.5" />
						</a>
					</>
				)}
			</CardContent>
		</Card>
	);
}

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
				<div className="text-sm text-muted-foreground">{label}</div>
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
					<Skeleton className="size-8 rounded-md shrink-0" />
					<div className="space-y-1.5">
						<Skeleton className="h-3 w-24" />
						<Skeleton className="h-5 w-16" />
						<Skeleton className="h-3 w-20" />
					</div>
				</div>
				<Separator />
				<div className="flex items-center justify-between gap-4">
					<div className="flex items-center gap-3">
						<Skeleton className="size-8 rounded-md shrink-0" />
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
