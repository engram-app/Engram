import { AlertCircle, Info, TriangleAlert, X } from "lucide-react";
import type * as React from "react";
import { Alert, AlertDescription } from "@/components/ui/alert";
import type { SubscriptionAlertData } from "@/lib/paddle-types";
import { type AlertVariant, deriveSubscriptionAlert } from "@/lib/subscription-alert-utils";
import { cn } from "@/lib/utils";

/** Props for the `SubscriptionAlert` component. */
export interface SubscriptionAlertProps {
	subscription?: SubscriptionAlertData;
	onDismiss?: () => void;
	className?: string;
}

const VARIANT_CONFIG: Record<AlertVariant, { icon: React.ElementType; className: string }> = {
	destructive: {
		icon: AlertCircle,
		className: "border-destructive/50 bg-destructive/15 text-destructive [&>svg]:text-destructive",
	},
	warning: {
		icon: TriangleAlert,
		className:
			"border-warning/40 bg-warning/15 text-warning-foreground [&>svg]:text-warning-foreground",
	},
	info: {
		icon: Info,
		className: "border-info/40 bg-info/15 text-info-foreground [&>svg]:text-info-foreground",
	},
};

export function SubscriptionAlert({ subscription, onDismiss, className }: SubscriptionAlertProps) {
	const alert = deriveSubscriptionAlert(subscription);

	if (!alert) {
		return null;
	}

	const config = VARIANT_CONFIG[alert.variant];
	const Icon = config.icon;

	return (
		<Alert className={cn("relative", config.className, className)}>
			<Icon className="size-4" />
			<AlertDescription className="flex items-center justify-between gap-4 text-inherit">
				<span>
					{alert.message}
					{alert.actionUrl && alert.actionLabel && (
						<>
							{" "}
							<a
								href={alert.actionUrl}
								target="_blank"
								rel="noopener noreferrer"
								className="font-medium underline underline-offset-2 hover:no-underline"
							>
								{alert.actionLabel}
							</a>
						</>
					)}
				</span>
				{onDismiss && (
					<button
						type="button"
						onClick={onDismiss}
						aria-label="Dismiss alert"
						className="shrink-0 rounded-sm opacity-60 transition-opacity hover:opacity-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
					>
						<X className="size-4" />
					</button>
				)}
			</AlertDescription>
		</Alert>
	);
}
