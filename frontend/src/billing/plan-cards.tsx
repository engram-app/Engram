import { ChevronDown } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { msg } from "@/i18n/msg";
import type { Translate } from "@/i18n/translate";
import type { MsgKey } from "@/i18n/ui-text";
import { intlLocale } from "@/lib/intl-locale";
import { formatMoney } from "@/lib/paddle-format";
import { cn } from "@/lib/utils";
import { type BillingCadence, useBillingConfig } from "../api/queries";

// Plan prices read "$7", not "$7.00"; Intl writes the sign for the reader's locale.
const WHOLE = { dropWholeCents: true };

// Feature checklist shared by the full card and the accordion row. `className`
// merges extra layout (e.g. `flex-1` on the full card).
function FeatureList({ features, className }: { features: readonly MsgKey[]; className?: string }) {
	const { t } = useT();
	return (
		<ul className={cn("space-y-1 text-muted-foreground text-sm", className)}>
			{features.map((f) => (
				<li key={f} className="flex items-center gap-2">
					<span className="text-primary-ink" aria-hidden="true">
						&#10003;
					</span>
					{t(f)}
				</li>
			))}
		</ul>
	);
}

interface FreeTierCopy {
	name: MsgKey;
	price: string;
	summary: MsgKey;
	features: readonly MsgKey[];
}

// Free tier display copy. Not a PlanTier (no Paddle price / checkout), but
// centralized here alongside the paid catalog so the onboarding accordion and
// the desktop free-link can't drift. Every stored note is searchable; the
// upgrade levers are the daily AI search limit and more vaults (and, with the
// v5 caps, more notes), so those are what the summary states.
const FREE_REST = [
	msg("20 AI searches a day"),
	msg("1 vault"),
	msg("1 GB attachments"),
	msg("2 devices"),
];

const FREE_TIER: Record<PlanLimits, FreeTierCopy> = {
	legacy: {
		name: msg("Free"),
		price: "$0",
		summary: msg("3,000 notes · 20 AI searches a day · 1 vault"),
		features: [msg("3,000 notes, all searchable"), ...FREE_REST],
	},
	v5: {
		name: msg("Free"),
		price: "$0",
		summary: msg("2,000 notes · 20 AI searches a day · 1 vault"),
		features: [msg("2,000 notes, all searchable"), ...FREE_REST],
	},
};

// The note-cap line is the only difference between the sets: Starter 50,000
// and Pro unlimited state none (legacy), the v5 caps state theirs.
function planCatalog(limits: PlanLimits): Record<PlanTier, PlanCardCatalog> {
	const v5 = limits === "v5";
	return {
		starter: {
			name: msg("Starter"),
			monthlyPrice: 7,
			annualPrice: 70,
			features: [
				...(v5 ? [msg("20,000 notes")] : []),
				msg("10 vaults"),
				msg("Unlimited devices"),
				msg("10 GB attachments"),
				msg("Unlimited AI searches"),
			],
		},
		pro: {
			name: msg("Pro"),
			monthlyPrice: 14,
			annualPrice: 140,
			// Lead with what is actually Pro-ONLY. Unlimited devices and unlimited
			// AI searches are true here too, but they are table stakes on paid and
			// listing them made Pro read as "Starter with more storage" at double
			// the price. `cross_vault_search` is the key that is genuinely pro-true
			// in `LimitKeys` (API access is every tier's since #1974). Reranking is also
			// pro-only but ships with RERANKER_BACKEND unset, so it stays off this
			// list until the backend is actually deployed.
			features: [
				msg("Unlimited vaults"),
				...(v5 ? [msg("40,000 notes")] : []),
				msg("50 GB attachments"),
				msg("Cross-vault search"),
			],
		},
	};
}

const PLAN_CATALOG: Record<PlanLimits, Record<PlanTier, PlanCardCatalog>> = {
	legacy: planCatalog("legacy"),
	v5: planCatalog("v5"),
};

interface PlanCardProps {
	name: MsgKey;
	cadence: BillingCadence;
	monthlyPrice: number;
	annualPrice: number;
	features: readonly MsgKey[];
	tier: PlanTier;
	onAction: (tier: PlanTier) => void;
	disabled?: boolean;
	// Visual states — pick at most one (current beats selected which beats
	// recommended). Only one card per panel should render any of these.
	recommended?: boolean;
	selected?: boolean;
	current?: boolean;
	ctaLabel?: string;
	// ctaSubLabel is shown under the CTA only on the selected card — used by
	// PlanChangePanel to surface inline proration without a separate strip.
	ctaSubLabel?: string;
}

export type PlanTier = "starter" | "pro";

export interface PlanCardCatalog {
	name: MsgKey;
	monthlyPrice: number;
	annualPrice: number;
	features: readonly MsgKey[];
}

// Display price for a plan at the given cadence. Single formatter so the
// monthly/annual string is identical everywhere it's shown (full cards +
// mobile accordion rows).
export function formatPlanPrice(
	catalog: Pick<PlanCardCatalog, "monthlyPrice" | "annualPrice">,
	cadence: BillingCadence,
	t: Translate,
	locale?: string,
): string {
	return cadence === "monthly"
		? t("{price}/mo", { price: formatMoney(catalog.monthlyPrice, "USD", locale, WHOLE) })
		: t("{price}/yr", { price: formatMoney(catalog.annualPrice, "USD", locale, WHOLE) });
}

// Which note caps the copy states: the set the backend enforces
// (`/billing/config` `plan_limits`, `Engram.Billing.LimitKeys.plan_limits/0`).
// "legacy" until the v5 go flag is on, and while the config loads, so a
// card never promises caps the backend is not enforcing.
export type PlanLimits = "legacy" | "v5";

// Single catalog source-of-truth: both onboarding (trial signup) and the
// change-plan panel read display prices from here. Keep in sync with the
// pricing model lock (Free / $7 / $14 monthly + $70/$140 annual — see
// memory project_pricing_model). Updating Paddle prices means updating here.
export const PLAN_TIERS: readonly PlanTier[] = ["starter", "pro"];

/** The plan copy for an enforced set; anything but "v5" reads as legacy. */
export function planCopy(limits: PlanLimits | undefined) {
	const set: PlanLimits = limits === "v5" ? "v5" : "legacy";
	return { freeTier: FREE_TIER[set], catalog: PLAN_CATALOG[set] };
}

/** `planCopy/1` for the set `/billing/config` reports. */
export function usePlanCopy() {
	const { data } = useBillingConfig();
	return planCopy(data?.plan_limits);
}

export function CadenceToggle({
	cadence,
	onChange,
}: {
	cadence: BillingCadence;
	onChange: (next: BillingCadence) => void;
}) {
	const { t } = useT();
	return (
		<div role="radiogroup" aria-label={t("Billing cadence")} className="flex justify-center">
			<div className="inline-flex rounded-full border border-border bg-muted p-1 text-sm">
				<label
					className={cn(
						"inline-flex cursor-pointer items-center justify-center rounded-full px-4 py-1.5 font-medium leading-none transition focus-within:ring-2 focus-within:ring-ring focus-within:ring-offset-1",
						cadence === "monthly"
							? "bg-primary text-primary-foreground"
							: "text-muted-foreground hover:text-foreground",
					)}
				>
					<input
						type="radio"
						name="billing-cadence"
						value="monthly"
						checked={cadence === "monthly"}
						onChange={() => onChange("monthly")}
						className="sr-only"
					/>
					{t("Monthly")}
				</label>
				<label
					className={cn(
						"inline-flex cursor-pointer items-center justify-center rounded-full px-4 py-1.5 font-medium leading-none transition focus-within:ring-2 focus-within:ring-ring focus-within:ring-offset-1",
						cadence === "annual"
							? "bg-primary text-primary-foreground"
							: "text-muted-foreground hover:text-foreground",
					)}
				>
					<input
						type="radio"
						name="billing-cadence"
						value="annual"
						checked={cadence === "annual"}
						onChange={() => onChange("annual")}
						className="sr-only"
					/>
					{t("Annual")}{" "}
					<span
						className={cn(
							"ml-1 text-xs",
							cadence === "annual" ? "text-primary-foreground/90" : "text-primary-ink",
						)}
					>
						{t("save 17%")}
					</span>
				</label>
			</div>
		</div>
	);
}

export function PlanCard({
	name,
	cadence,
	monthlyPrice,
	annualPrice,
	features,
	tier,
	onAction,
	disabled = false,
	recommended = false,
	selected = false,
	current = false,
	ctaLabel,
	ctaSubLabel,
}: PlanCardProps) {
	const { t, renderedLocale } = useT();
	const locale = intlLocale(renderedLocale, "en-US");
	const price = formatPlanPrice({ monthlyPrice, annualPrice }, cadence, t, locale);
	// The amount and the billing words are separate strings, so no translation
	// holds the price: a model given "{price}/mo billed yearly" decorated the
	// amount with a currency of its own ("$5.83 руб./мес.").
	const subPrice =
		cadence === "annual"
			? `${t("{price}/mo", { price: formatMoney(Math.round((annualPrice / 12) * 100) / 100, "USD", locale, WHOLE) })} · ${t("billed yearly")}`
			: `${t("{price}/yr", { price: formatMoney(monthlyPrice * 12, "USD", locale, WHOLE) })} · ${t("billed monthly")}`;

	// Effective state precedence — current beats selected beats recommended.
	// Avoids the "everything is highlighted" failure mode if a parent passes
	// multiple truthy flags by mistake.
	const state: "current" | "selected" | "recommended" | "idle" = current
		? "current"
		: selected
			? "selected"
			: recommended
				? "recommended"
				: "idle";

	const badgeText =
		state === "current" ? t("Your plan") : state === "recommended" ? t("Most popular") : null;

	const filled = state === "recommended" || state === "selected";
	return (
		<li
			className={cn(
				"relative flex flex-col gap-4 rounded-lg border bg-card p-6 transition duration-150",
				state === "idle" && "border-border hover:-translate-y-0.5 hover:border-primary/60",
				state === "recommended" && "border-primary ring-1 ring-primary hover:-translate-y-0.5",
				state === "selected" && "border-primary shadow-sm ring-2 ring-primary",
				// 'current' reads as "you've got this" — primary accent ring, no
				// muted bg. Diminished-grey treatment made the card feel locked
				// out; this leans into the card visually instead.
				state === "current" && "border-primary/60 shadow-sm ring-1 ring-primary/30",
			)}
		>
			{Boolean(badgeText) && (
				<span className="absolute -top-3 left-6 rounded-full bg-primary px-2.5 py-0.5 font-semibold text-primary-foreground text-xs uppercase tracking-wide">
					{badgeText}
				</span>
			)}
			<h3 className="font-semibold text-lg">{t(name)}</h3>
			<p className="font-bold text-2xl">{price}</p>
			<p className="-mt-3 text-muted-foreground text-xs">{subPrice}</p>
			<FeatureList features={features} className="flex-1" />
			<div className="flex flex-col gap-1">
				{current ? (
					// Inert positive indicator instead of a disabled button: same
					// height as the CTA so card layout stays consistent, but
					// visually reads as confirmation, not as a denied action.
					<div
						role="status"
						aria-label={t("Your current plan")}
						className="flex w-full items-center justify-center gap-2 rounded-lg border border-primary/40 bg-primary/10 px-4 py-2 font-medium text-primary-ink text-sm"
					>
						<span aria-hidden="true">&#10003;</span>
						<span>{t("You're on this plan")}</span>
					</div>
				) : (
					<>
						<Button
							type="button"
							onClick={() => onAction(tier)}
							disabled={disabled}
							// recommended (onboarding's Pro) and selected (change-plan's
							// chosen target) get the filled-primary CTA so the actionable
							// card has weight. idle stays a clean outline.
							variant={filled ? "default" : "outline"}
							className="w-full"
						>
							{ctaLabel ?? t("Start free trial")}
						</Button>
						{Boolean(selected && ctaSubLabel) && (
							<p className="text-center text-muted-foreground text-xs">{ctaSubLabel}</p>
						)}
					</>
				)}
			</div>
		</li>
	);
}

// Collapsible secondary tier for the mobile plan step. The header (always
// visible) carries the name + formatted price + a one-line gist so basic
// comparison survives while collapsed; tapping reveals the full feature list
// and CTA. Open/close is controlled by the parent so the rows behave as a
// strict accordion (one open at a time). Price is pre-formatted so this stays
// cadence-agnostic and reusable for the $0 Free row (different handler).
export function PlanAccordionRow({
	name,
	price,
	summary,
	features,
	ctaLabel,
	ctaNote,
	onClick,
	open,
	onOpen,
	disabled = false,
	recommended = false,
	quietCta = false,
}: {
	name: MsgKey;
	price: string;
	summary: string;
	features: readonly MsgKey[];
	ctaLabel: string;
	ctaNote?: string;
	onClick: () => void;
	open: boolean;
	onOpen: () => void;
	disabled?: boolean;
	recommended?: boolean;
	quietCta?: boolean;
}) {
	const { t } = useT();
	return (
		<li
			className={cn(
				"overflow-hidden rounded-lg border bg-card transition-colors",
				// The open tier carries the primary border; the Popular pill (keyed to
				// `recommended`) stays on Pro regardless of which row is open.
				open ? "border-primary ring-1 ring-primary" : "border-border",
			)}
		>
			<button
				type="button"
				onClick={onOpen}
				aria-expanded={open}
				className="flex w-full items-center justify-between gap-3 p-4 text-left"
			>
				<span className="flex min-w-0 flex-col gap-1">
					<span className="flex flex-wrap items-center gap-x-2 font-semibold text-foreground text-sm">
						<span>{t(name)}</span>
						{Boolean(recommended) && (
							<span className="inline-flex items-center rounded-full bg-primary px-2 pt-[4px] pb-[2px] font-semibold text-[10px] text-primary-foreground uppercase leading-none tracking-wide">
								{t("Popular")}
							</span>
						)}
						<span className="font-normal text-muted-foreground">· {price}</span>
					</span>
					<span className="block text-muted-foreground text-xs">{summary}</span>
				</span>
				<ChevronDown
					aria-hidden="true"
					className={cn(
						"size-4 shrink-0 text-muted-foreground/50 transition-transform duration-150",
						open && "rotate-180",
					)}
				/>
			</button>
			{/* Smooth height animation via the grid 0fr→1fr technique: content is
          always rendered (so it can animate both ways) and clipped by the inner
          overflow-hidden; a fade adds polish. */}
			<div
				className={cn(
					"grid transition-[grid-template-rows] duration-200 ease-out",
					open ? "grid-rows-[1fr]" : "grid-rows-[0fr]",
				)}
			>
				<div className="overflow-hidden">
					<div className="px-4 pb-4">
						<FeatureList features={features} />
						<Button
							type="button"
							onClick={onClick}
							disabled={disabled}
							tabIndex={open ? 0 : -1}
							// Paid tiers get the strong filled CTA; Free is intentionally
							// quieter (outline) so it doesn't pull weight from the revenue
							// tiers.
							variant={quietCta ? "outline" : "default"}
							className="mt-3 w-full"
						>
							{ctaLabel}
						</Button>
						{Boolean(ctaNote) && (
							<p className="mt-1.5 text-center text-muted-foreground text-xs">{ctaNote}</p>
						)}
					</div>
				</div>
			</div>
		</li>
	);
}
