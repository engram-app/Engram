import { useEffect } from "react";
import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";
import { useT } from "@/i18n/locale-provider";
import { msg } from "@/i18n/msg";
import { intlLocale } from "@/lib/intl-locale";
import { track } from "../../analytics/track";
import { useOpenBilling } from "../../billing/use-open-billing";
import { formatBytes } from "../attachment-preview";
import type { PlanLimits, UploadLimits } from "./upload-limits";

type Tier = "free" | "starter" | "pro";

const TIER_NAMES = { free: msg("Free"), starter: msg("Starter"), pro: msg("Pro") } as const;

interface Props {
	tooLarge: File[];
	noRoom: File[];
	tier: Tier;
	limits: UploadLimits;
	planLimits: PlanLimits;
	billingEnabled: boolean;
	onClose: () => void;
}

/**
 * Says why files were refused before upload: over the per-file limit, or no
 * room left in storage. With billing on it names what each paid plan allows,
 * only for plans that would actually raise the limit, and offers Upgrade.
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
	const largest = Math.max(0, ...tooLarge.map((f) => f.size));
	const needed = noRoom.reduce((sum, f) => sum + f.size, 0);

	// Same funnel event the server-refusal paywall sends.
	useEffect(() => {
		track("paywall_shown", {
			limit_key: tooLarge.length > 0 ? "file_too_large" : "attachments_quota_exceeded",
		});
	}, [tooLarge.length]);

	// Paid plans that would let these files in, with their number.
	const offers = (key: "max_file_bytes" | "attachment_bytes_cap", fits: (cap: number) => boolean) =>
		(["starter", "pro"] as const).flatMap((p) => {
			if (p === tier) {
				return [];
			}
			const cap = planLimits[p]?.[key];
			return cap === undefined || (cap !== null && !fits(cap)) ? [] : [{ p, cap }];
		});
	const fileOffers = offers("max_file_bytes", (cap) => cap >= largest);
	const roomOffers = offers("attachment_bytes_cap", (cap) => cap >= limits.usedBytes + needed);
	const showUpgrade =
		billingEnabled &&
		((tooLarge.length > 0 && fileOffers.length > 0) ||
			(noRoom.length > 0 && roomOffers.length > 0));

	const [first] = tooLarge;
	const [firstNoRoom] = noRoom;

	return (
		<Dialog open onOpenChange={(open) => !open && onClose()}>
			<DialogContent>
				<DialogHeader>
					<DialogTitle>
						{tooLarge.length === 1 && first
							? t("{name} is too large to upload", { name: first.name })
							: tooLarge.length > 1
								? tn(
										{
											one: "{count} file is too large to upload",
											other: "{count} files are too large to upload",
										},
										tooLarge.length,
									)
								: noRoom.length === 1 && firstNoRoom
									? t("Not enough storage for {name}", { name: firstNoRoom.name })
									: tn(
											{
												one: "Not enough storage for {count} file",
												other: "Not enough storage for {count} files",
											},
											noRoom.length,
										)}
					</DialogTitle>
					<DialogDescription asChild>
						<div className="flex flex-col gap-2">
							{tooLarge.length > 0 && limits.maxFileBytes !== null ? (
								<p>
									{billingEnabled
										? tooLarge.length === 1
											? t("It's {size}. Your {plan} plan uploads files up to {limit}.", {
													size: fmt(largest),
													plan,
													limit: fmt(limits.maxFileBytes),
												})
											: t("Your {plan} plan uploads files up to {limit}.", {
													plan,
													limit: fmt(limits.maxFileBytes),
												})
										: t("This server uploads files up to {limit}.", {
												limit: fmt(limits.maxFileBytes),
											})}
								</p>
							) : null}
							{noRoom.length > 0 && limits.storageCap !== null ? (
								<p>
									{billingEnabled
										? t("You've used {used} of your {plan} plan's {cap}.", {
												used: fmt(limits.usedBytes),
												plan,
												cap: fmt(limits.storageCap),
											})
										: t("This server's storage is full: {used} of {cap} used.", {
												used: fmt(limits.usedBytes),
												cap: fmt(limits.storageCap),
											})}
								</p>
							) : null}
						</div>
					</DialogDescription>
				</DialogHeader>

				{tooLarge.length + noRoom.length > 1 ? (
					<ul className="max-h-40 overflow-auto text-sm" translate="no">
						{[...tooLarge, ...noRoom].map((file, i) => (
							// Two dropped files can share a name; position keeps rows apart.
							// biome-ignore lint/suspicious/noArrayIndexKey: position is the only stable identity.
							<li key={i} className="flex justify-between gap-4">
								<span className="truncate">{file.name}</span>
								<span className="shrink-0 text-muted-foreground">{fmt(file.size)}</span>
							</li>
						))}
					</ul>
				) : null}

				{showUpgrade ? (
					<ul className="text-sm">
						{tooLarge.length > 0
							? fileOffers.map(({ p, cap }) => (
									<li key={`f-${p}`}>
										{cap === null
											? t("{plan}: no file size limit", { plan: t(TIER_NAMES[p]) })
											: t("{plan}: files up to {limit}", {
													plan: t(TIER_NAMES[p]),
													limit: fmt(cap),
												})}
									</li>
								))
							: null}
						{noRoom.length > 0
							? roomOffers.map(({ p, cap }) => (
									<li key={`s-${p}`}>
										{cap === null
											? t("{plan}: unlimited storage", { plan: t(TIER_NAMES[p]) })
											: t("{plan}: {cap} of storage", { plan: t(TIER_NAMES[p]), cap: fmt(cap) })}
									</li>
								))
							: null}
					</ul>
				) : null}

				<DialogFooter>
					<Button variant={showUpgrade ? "outline" : "default"} onClick={onClose}>
						{t("OK")}
					</Button>
					{showUpgrade ? (
						<Button
							onClick={() => {
								onClose();
								openBilling();
							}}
						>
							{t("Upgrade")}
						</Button>
					) : null}
				</DialogFooter>
			</DialogContent>
		</Dialog>
	);
}
