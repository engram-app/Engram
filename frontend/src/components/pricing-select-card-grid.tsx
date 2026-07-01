import { RadioGroup as RadioGroupPrimitive } from "radix-ui";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/utils";
import { CheckIcon } from "lucide-react";
import type { PriceData } from "@/lib/paddle-types";

export type PricingSelectCardGridProps = {
	priceId: string;
	name: string;
	priceData?: PriceData;
	description?: string;
	badge?: string;
	badgePosition?: "left" | "center" | "right";
	isCurrent?: boolean;
	currentPlanLabel?: string;
	showInterval?: boolean;
	loading?: boolean;
	className?: string;
};

export function PricingSelectCardGrid({
	priceId,
	name,
	priceData,
	description,
	badge,
	badgePosition = "center",
	isCurrent = false,
	currentPlanLabel = "Current plan",
	showInterval = true,
	loading = false,
	className,
}: PricingSelectCardGridProps) {
	const { total, originalTotal, interval, trialPeriod } = priceData ?? {};

	const showBadges = badge || isCurrent;

	if (loading) {
		return (
			<Card className={cn("relative p-5 text-center", className)}>
				<Skeleton className="mx-auto mb-2 h-5 w-20" />
				<Skeleton className="mx-auto mb-6 h-8 w-24" />
				<Skeleton className="mx-auto h-5 w-5 rounded-full" />
			</Card>
		);
	}

	return (
		<RadioGroupPrimitive.Item value={priceId} disabled={isCurrent} asChild>
			<Card
				className={cn(
					"relative flex cursor-pointer flex-col items-center justify-center overflow-visible rounded-lg border p-5 shadow-none transition-all hover:shadow-md",
					"data-[state=checked]:border-2 data-[state=checked]:border-primary data-[state=checked]:bg-primary/5",
					isCurrent && "cursor-default border-muted bg-muted/30 hover:shadow-none",
					className,
				)}
			>
				{showBadges && (
					<div
						className={cn(
							"absolute -top-3 z-10 flex gap-1.5",
							badgePosition === "left" && "left-4",
							badgePosition === "center" && "left-1/2 -translate-x-1/2",
							badgePosition === "right" && "right-4",
						)}
					>
						{badge && <Badge className="bg-primary text-primary-foreground">{badge}</Badge>}
						{isCurrent && <Badge variant="secondary">{currentPlanLabel}</Badge>}
					</div>
				)}

				<CardHeader className="flex-1 p-0 flex flex-col items-center justify-center text-center">
					<CardTitle className="text-base font-medium">{name}</CardTitle>
					{description && <div className="text-muted-foreground text-xs mt-0.5">{description}</div>}
					{originalTotal && (
						<div className="text-muted-foreground text-sm line-through mt-2">{originalTotal}</div>
					)}
					<div className="text-2xl font-bold mt-2">{total}</div>
					{showInterval && interval && (
						<div className="text-muted-foreground text-xs">per {interval}</div>
					)}
					{trialPeriod && (
						<div className="text-muted-foreground text-xs mt-1">{trialPeriod} free trial</div>
					)}
				</CardHeader>

				<CardContent className="mt-6 flex items-center justify-center p-0">
					<RadioGroupPrimitive.Indicator asChild forceMount>
						<div
							className={cn(
								"group flex aspect-square size-5 shrink-0 items-center justify-center rounded-full border transition-colors",
								"border-input data-[state=checked]:border-primary data-[state=checked]:bg-primary",
							)}
						>
							<CheckIcon className="size-4 text-primary-foreground opacity-0 group-data-[state=checked]:opacity-100 transition-opacity" />
						</div>
					</RadioGroupPrimitive.Indicator>
				</CardContent>
			</Card>
		</RadioGroupPrimitive.Item>
	);
}
