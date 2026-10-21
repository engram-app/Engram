import { File as FileIcon, FileWarning, HardDrive } from "lucide-react";
import { useEffect } from "react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useT } from "@/i18n/locale-provider";
import { msg } from "@/i18n/msg";
import { intlLocale } from "@/lib/intl-locale";
import { cn } from "@/lib/utils";
import { track } from "../../analytics/track";
import { useOpenBilling } from "../../billing/use-open-billing";
import { formatBytes } from "../attachment-preview";
import type { PlanLimits, UploadLimits } from "./upload-limits";

type Tier = "free" | "starter" | "pro";
type Metric = "max_file_bytes" | "attachment_bytes_cap";

const TIER_NAMES = { free: msg("Free"), starter: msg("Starter"), pro: msg("Pro") } as const;
const TIERS: readonly Tier[] = ["free", "starter", "pro"];

interface Props {
	tooLarge: File[];
	noRoom: File[];
	tier: Tier;
	limits: UploadLimits;
	planLimits: PlanLimits;
	billingEnabled: boolean;
	onClose: () => void;
}

// One refused file per row. The name lives here, not inside a sentence, so a
// long name truncates on its own line instead of breaking the copy around it.
function FileRows({ files, fmt }: { files: File[]; fmt: (n: number) => string }) {
	const rows = (
		<ul className="divide-y divide-border">
			{files.map((file, i) => (
				// Two dropped files can share a name; position keeps rows apart.
				// biome-ignore lint/suspicious/noArrayIndexKey: position is the only stable identity.
				<li key={i} className="flex items-center gap-3 px-3 py-2.5">
					<FileIcon className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
					<span
						className="min-w-0 flex-1 truncate font-medium text-sm"
						title={file.name}
						translate="no"
					>
						{file.name}
					</span>
					<span className="shrink-0 text-muted-foreground text-sm tabular-nums">
						{fmt(file.size)}
					</span>
				</li>
			))}
		</ul>
	);
	return (
		<section className="overflow-hidden rounded-lg border">
			{/* Grows with the list up to five rows, then scrolls. */}
			<ScrollArea viewportClassName="max-h-44">{rows}</ScrollArea>
		</section>
	);
}

/**
 * Explains files refused before upload: over the per-file limit, or no room
 * left in storage. With billing on it compares the plans and offers Upgrade;
 * without (self-host) it states the server's limit.
 */
export function UploadLimitDialog({
	tooLarge,
	noRoom,
	tier,
	limits,
	planLimits,
	billingEnabled,
	onClose,
}: Props) {
	const { t, tn, renderedLocale } = useT();
	const openBilling = useOpenBilling("paywall");
	const fmt = (n: number) => formatBytes(n, intlLocale(renderedLocale));
	const plan = t(TIER_NAMES[tier]);
	const sizeCase = tooLarge.length > 0;
	const files = sizeCase ? tooLarge : noRoom;
	const metric: Metric = sizeCase ? "max_file_bytes" : "attachment_bytes_cap";
	const current = sizeCase ? limits.maxFileBytes : limits.storageCap;

	// Same funnel event the server-refusal paywall sends.
	useEffect(() => {
		track("paywall_shown", {
			limit_key: sizeCase ? "file_too_large" : "attachments_quota_exceeded",
		});
	}, [sizeCase]);

	// This plan and the ones above it; a plan below the user's is not an offer.
	const tiers = TIERS.slice(TIERS.indexOf(tier)).map((p) => ({
		p,
		value: p === tier ? current : p === "free" ? null : planLimits[p]?.[metric],
	}));
	const showPlans =
		billingEnabled && tiers.length > 1 && tiers.slice(1).some((x) => x.value !== undefined);

	const title = sizeCase
		? tn({ one: "File too large", other: "Files too large" }, tooLarge.length)
		: t("Not enough storage");
	const limit = current === null ? "" : fmt(current);
	const description = sizeCase
		? billingEnabled
			? tn(
					{
						one: "This file is over the {limit} upload limit on your {plan} plan.",
						other: "These files are over the {limit} upload limit on your {plan} plan.",
					},
					tooLarge.length,
					{ limit, plan },
				)
			: tn(
					{
						one: "This file is over this server's {limit} upload limit.",
						other: "These files are over this server's {limit} upload limit.",
					},
					tooLarge.length,
					{ limit },
				)
		: billingEnabled
			? tn(
					{
						one: "There isn't enough room left on your {plan} plan for this file.",
						other: "There isn't enough room left on your {plan} plan for these files.",
					},
					noRoom.length,
					{ plan },
				)
			: tn(
					{
						one: "There isn't enough room left on this server for this file.",
						other: "There isn't enough room left on this server for these files.",
					},
					noRoom.length,
				);
	const Icon = sizeCase ? FileWarning : HardDrive;

	return (
		<Dialog open onOpenChange={(open) => !open && onClose()}>
			<DialogContent className="gap-5 sm:max-w-md">
				<DialogHeader className="gap-3">
					<span className="flex items-center gap-2.5">
						<Icon className="size-5 shrink-0 text-destructive" aria-hidden="true" />
						<DialogTitle asChild>
							<h1 className="font-heading font-semibold text-foreground text-xl tracking-tight">
								{title}
							</h1>
						</DialogTitle>
					</span>
					<DialogDescription className="text-foreground/80 text-sm leading-relaxed">
						{description}
					</DialogDescription>
				</DialogHeader>

				<FileRows files={files} fmt={fmt} />

				{!sizeCase && limits.storageCap !== null ? (
					<section className="flex flex-col gap-1.5">
						<p className="flex justify-between text-sm">
							<span className="text-muted-foreground">{t("Storage used")}</span>
							<span className="tabular-nums">
								{t("{used} of {cap}", { used: fmt(limits.usedBytes), cap: fmt(limits.storageCap) })}
							</span>
						</p>
						<meter
							aria-label={t("Storage used")}
							min={0}
							max={limits.storageCap}
							value={limits.usedBytes}
							className="h-1.5 w-full appearance-none overflow-hidden rounded-full bg-foreground/10 [&::-moz-meter-bar]:bg-destructive [&::-webkit-meter-bar]:rounded-full [&::-webkit-meter-bar]:border-0 [&::-webkit-meter-bar]:bg-foreground/10 [&::-webkit-meter-optimum-value]:bg-destructive"
						/>
					</section>
				) : null}

				{showPlans ? (
					<section aria-label={t("Compare plans")} className="flex flex-col gap-2">
						<h2 className="font-medium text-muted-foreground text-xs uppercase tracking-wide">
							{sizeCase ? t("Upload limit by plan") : t("Storage by plan")}
						</h2>
						<ul className={cn("grid gap-2", tiers.length === 3 ? "grid-cols-3" : "grid-cols-2")}>
							{tiers.map(({ p, value }) => (
								<li
									key={p}
									className={cn(
										"flex flex-col gap-1 rounded-lg border px-3 py-2.5",
										p === tier ? "bg-muted/40" : "border-primary/40",
									)}
								>
									<span className="flex items-center justify-between gap-1 text-sm">
										<span className="font-medium">{t(TIER_NAMES[p])}</span>
										{p === tier ? (
											<Badge variant="secondary" className="px-1.5 text-[10px]">
												{t("Current")}
											</Badge>
										) : null}
									</span>
									<span className="font-semibold text-lg tabular-nums">
										{value === null || value === undefined ? t("No limit") : fmt(value)}
									</span>
								</li>
							))}
						</ul>
					</section>
				) : null}

				<DialogFooter>
					{showPlans ? (
						<Button
							className="w-full"
							size="lg"
							onClick={() => {
								onClose();
								openBilling();
							}}
						>
							{t("Upgrade")}
						</Button>
					) : (
						<Button className="w-full sm:w-auto" onClick={onClose}>
							{t("OK")}
						</Button>
					)}
				</DialogFooter>
			</DialogContent>
		</Dialog>
	);
}
