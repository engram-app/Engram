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
	const fileLimit = limits.maxFileBytes === null ? "" : fmt(limits.maxFileBytes);
	const limitLine = billingEnabled
		? t("Your {plan} plan uploads files up to {limit}.", { plan, limit: fileLimit })
		: t("This server uploads files up to {limit}.", { limit: fileLimit });
	const storageLine =
		limits.storageCap === null
			? ""
			: billingEnabled
				? t("You've used {used} of your {plan} plan's {cap}.", {
						used: fmt(limits.usedBytes),
						plan,
						cap: fmt(limits.storageCap),
					})
				: t("This server's storage is full: {used} of {cap} used.", {
						used: fmt(limits.usedBytes),
						cap: fmt(limits.storageCap),
					});

	return (
		<Dialog open onOpenChange={(open) => !open && onClose()}>
			<DialogContent>
				<DialogHeader>
					<DialogTitle>
						{tooLarge.length === 0
							? t("Storage full")
							: tooLarge.length === 1
								? t("File too large")
								: t("Files too large")}
					</DialogTitle>
					{/* The reason IS the content here, so it reads as body text, not a muted caption. */}
					<DialogDescription asChild>
						<div className="flex flex-col gap-2 text-base text-foreground">
							{tooLarge.length > 0 ? (
								<p>
									{tooLarge.length === 1 && first
										? t("{name} is {size}.", { name: first.name, size: fmt(first.size) })
										: tn(
												{
													one: "{count} file is over the limit.",
													other: "{count} files are over the limit.",
												},
												tooLarge.length,
											)}{" "}
									{limitLine}
								</p>
							) : null}
							{noRoom.length > 0 ? (
								<p>
									{noRoom.length === 1 && firstNoRoom
										? t("{name} doesn't fit.", { name: firstNoRoom.name })
										: tn(
												{ one: "{count} file doesn't fit.", other: "{count} files don't fit." },
												noRoom.length,
											)}{" "}
									{storageLine}
								</p>
							) : null}
						</div>
					</DialogDescription>
				</DialogHeader>

				{tooLarge.length + noRoom.length > 1 ? (
					<ul className="max-h-40 overflow-auto rounded-md border px-3 py-2 text-sm" translate="no">
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
					<section className="flex flex-col gap-1 rounded-md bg-muted/50 px-3 py-2 text-sm">
						<h3 className="font-medium">{t("Upgrade for more")}</h3>
						<ul>
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
					</section>
				) : null}

				<DialogFooter>
					{showUpgrade ? (
						<Button
							onClick={() => {
								onClose();
								openBilling();
							}}
						>
							{t("Upgrade")}
						</Button>
					) : (
						<Button onClick={onClose}>{t("OK")}</Button>
					)}
				</DialogFooter>
			</DialogContent>
		</Dialog>
	);
}
