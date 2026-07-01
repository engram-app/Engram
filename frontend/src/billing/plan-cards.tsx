import { ChevronDown } from "lucide-react";
import { cn } from "@/lib/utils";
import { ctaFilled, ctaOutline } from "@/lib/ui-classes";
import type { BillingCadence } from "../api/queries";

export type PlanTier = "starter" | "pro";

export interface PlanCardCatalog {
	name: string;
	monthlyPrice: number;
	annualPrice: number;
	features: string[];
}

// Display price for a plan at the given cadence. Single formatter so the
// monthly/annual string is identical everywhere it's shown (full cards +
// mobile accordion rows).
export function formatPlanPrice(
	catalog: Pick<PlanCardCatalog, "monthlyPrice" | "annualPrice">,
	cadence: BillingCadence,
): string {
	return cadence === "monthly" ? `$${catalog.monthlyPrice}/mo` : `$${catalog.annualPrice}/yr`;
}

// Free tier display copy. Not a PlanTier (no Paddle price / checkout), but
// centralized here alongside the paid catalog so the onboarding accordion and
// the desktop free-link can't drift.
export const FREE_TIER = {
	name: "Free",
	price: "$0",
	summary: "10k notes · 1 vault · markdown only",
	features: ["10k notes", "1 vault", "Markdown only", "Upgrade anytime"],
} as const;

// Feature checklist shared by the full card and the accordion row. `className`
// merges extra layout (e.g. `flex-1` on the full card).
function FeatureList({ features, className }: { features: string[]; className?: string }) {
	return (
		<ul className={cn("space-y-1 text-sm text-muted-foreground", className)}>
			{features.map((f) => (
				<li key={f} className="flex items-center gap-2">
					<span className="text-primary" aria-hidden="true">
						&#10003;
					</span>
					{f}
				</li>
			))}
		</ul>
	);
}

// Single catalog source-of-truth: both onboarding (trial signup) and the
// change-plan panel read display prices from here. Keep in sync with the
// pricing model lock (Free / $7 / $14 monthly + $70/$140 annual — see
// memory project_pricing_model). Updating Paddle prices means updating here.
export const PLAN_CATALOG: Record<PlanTier, PlanCardCatalog> = {
	starter: {
		name: "Starter",
		monthlyPrice: 7,
		annualPrice: 70,
		features: ["5 vaults", "Unlimited devices", "3 GB attachments", "500 AI queries/day"],
	},
	pro: {
		name: "Pro",
		monthlyPrice: 14,
		annualPrice: 140,
		features: [
			"15 vaults",
			"Unlimited devices",
			"15 GB attachments",
			"Unlimited AI",
			"Smart retrieval (coming)",
		],
	},
};

export function CadenceToggle({
	cadence,
	onChange,
}: {
	cadence: BillingCadence;
	onChange: (next: BillingCadence) => void;
}) {
	return (
		<div role="radiogroup" aria-label="Billing cadence" className="flex justify-center">
			<div className="inline-flex rounded-full border border-border bg-muted p-1 text-sm">
				<button
					role="radio"
					aria-checked={cadence === "monthly"}
					onClick={() => onChange("monthly")}
					className={cn(
						"inline-flex items-center justify-center rounded-full px-4 py-1.5 font-medium leading-none transition",
						cadence === "monthly"
							? "bg-primary text-primary-foreground"
							: "text-muted-foreground hover:text-foreground",
					)}
				>
					Monthly
				</button>
				<button
					role="radio"
					aria-checked={cadence === "annual"}
					onClick={() => onChange("annual")}
					className={cn(
						"inline-flex items-center justify-center rounded-full px-4 py-1.5 font-medium leading-none transition",
						cadence === "annual"
							? "bg-primary text-primary-foreground"
							: "text-muted-foreground hover:text-foreground",
					)}
				>
					Annual{" "}
					<span
						className={cn(
							"ml-1 text-xs",
							cadence === "annual" ? "text-primary-foreground/90" : "text-primary",
						)}
					>
						save 17%
					</span>
				</button>
			</div>
		</div>
	);
}

interface PlanCardProps {
	name: string;
	cadence: BillingCadence;
	monthlyPrice: number;
	annualPrice: number;
	features: string[];
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
	ctaLabel = "Start free trial",
	ctaSubLabel,
}: PlanCardProps) {
	const price = formatPlanPrice({ monthlyPrice, annualPrice }, cadence);
	const subPrice =
		cadence === "annual"
			? `$${(annualPrice / 12).toFixed(2)}/mo billed yearly`
			: `$${monthlyPrice * 12}/yr billed monthly`;

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
		state === "current" ? "Your plan" : state === "recommended" ? "Most popular" : null;

	return (
		<li
			className={cn(
				"relative flex flex-col gap-4 rounded-lg border bg-card p-6 transition duration-150",
				state === "idle" && "border-border hover:-translate-y-0.5 hover:border-primary/60",
				state === "recommended" && "border-primary ring-1 ring-primary hover:-translate-y-0.5",
				state === "selected" && "border-primary ring-2 ring-primary shadow-sm",
				// 'current' reads as "you've got this" — primary accent ring, no
				// muted bg. Diminished-grey treatment made the card feel locked
				// out; this leans into the card visually instead.
				state === "current" && "border-primary/60 ring-1 ring-primary/30 shadow-sm",
			)}
		>
			{badgeText && (
				<span className="absolute -top-3 left-6 rounded-full bg-primary px-2.5 py-0.5 text-xs font-semibold uppercase tracking-wide text-primary-foreground">
					{badgeText}
				</span>
			)}
			<h3 className="text-lg font-semibold">{name}</h3>
			<p className="text-2xl font-bold">{price}</p>
			<p className="-mt-3 text-xs text-muted-foreground">{subPrice}</p>
			<FeatureList features={features} className="flex-1" />
			<div className="flex flex-col gap-1">
				{current ? (
					// Inert positive indicator instead of a disabled button: same
					// height as the CTA so card layout stays consistent, but
					// visually reads as confirmation, not as a denied action.
					<div
						role="status"
						aria-label="Your current plan"
						className="flex w-full items-center justify-center gap-2 rounded-lg border border-primary/40 bg-primary/10 px-4 py-2 text-sm font-medium text-primary"
					>
						<span aria-hidden="true">&#10003;</span>
						<span>You're on this plan</span>
					</div>
				) : (
					<>
						<button
							onClick={() => onAction(tier)}
							disabled={disabled}
							className={cn(
								"w-full rounded-lg px-4 py-2 text-sm font-medium transition disabled:cursor-not-allowed disabled:opacity-50",
								// recommended (onboarding's Pro) and selected (change-plan's
								// chosen target) get filled-primary CTA so the actionable
								// card has weight. idle stays a clean outline.
								state === "recommended" || state === "selected" ? ctaFilled : ctaOutline,
							)}
						>
							{ctaLabel}
						</button>
						{selected && ctaSubLabel && (
							<p className="text-center text-xs text-muted-foreground">{ctaSubLabel}</p>
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
	name: string;
	price: string;
	summary: string;
	features: string[];
	ctaLabel: string;
	ctaNote?: string;
	onClick: () => void;
	open: boolean;
	onOpen: () => void;
	disabled?: boolean;
	recommended?: boolean;
	quietCta?: boolean;
}) {
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
					<span className="flex flex-wrap items-center gap-x-2 text-sm font-semibold text-foreground">
						<span>{name}</span>
						{recommended && (
							<span className="inline-flex items-center rounded-full bg-primary px-2 pb-[2px] pt-[4px] text-[10px] font-semibold uppercase leading-none tracking-wide text-primary-foreground">
								Popular
							</span>
						)}
						<span className="font-normal text-muted-foreground">· {price}</span>
					</span>
					<span className="block text-xs text-muted-foreground">{summary}</span>
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
						<button
							type="button"
							onClick={onClick}
							disabled={disabled}
							tabIndex={open ? 0 : -1}
							className={cn(
								"mt-3 w-full rounded-lg px-4 py-2 text-sm font-medium transition disabled:cursor-not-allowed disabled:opacity-50",
								// Paid tiers get the strong filled CTA; Free is intentionally
								// quieter (outline) so it doesn't pull weight from the revenue
								// tiers.
								quietCta ? ctaOutline : ctaFilled,
							)}
						>
							{ctaLabel}
						</button>
						{ctaNote && (
							<p className="mt-1.5 text-center text-xs text-muted-foreground">{ctaNote}</p>
						)}
					</div>
				</div>
			</div>
		</li>
	);
}
