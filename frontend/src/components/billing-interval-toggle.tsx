"use client";

import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { cn } from "@/lib/utils";
import { formatIntervalLabel } from "@/lib/paddle-format";

export type BillingIntervalToggleProps = {
	intervals: string[];
	value: string;
	onValueChange: (value: string) => void;
	className?: string;
};

export function BillingIntervalToggle({
	intervals,
	value,
	onValueChange,
	className,
}: BillingIntervalToggleProps) {
	return (
		<Tabs value={value} onValueChange={onValueChange} className={cn("w-full", className)}>
			<TabsList className="mx-auto flex w-fit">
				{intervals.map((interval) => (
					<TabsTrigger key={interval} value={interval}>
						{formatIntervalLabel(interval)}
					</TabsTrigger>
				))}
			</TabsList>
		</Tabs>
	);
}
