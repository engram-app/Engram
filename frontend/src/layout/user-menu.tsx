import { LogOut, MessageSquare, Monitor, Moon, Settings, Sparkles, Sun } from "lucide-react";
import { useState } from "react";
import { Link, useLocation } from "react-router";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
	DropdownMenu,
	DropdownMenuContent,
	DropdownMenuItem,
	DropdownMenuLabel,
	DropdownMenuRadioGroup,
	DropdownMenuRadioItem,
	DropdownMenuSeparator,
	DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useT } from "@/i18n/locale-provider";
import { msg } from "@/i18n/msg";
import type { MsgKey } from "@/i18n/ui-text";
import { useBillingStatus } from "../api/queries";
import { useAuthAdapter } from "../auth/use-auth-adapter";
import { FREE_TIER, PLAN_CATALOG } from "../billing/plan-cards";
import { useOpenBilling } from "../billing/use-open-billing";
import { useConfig } from "../config-context";
import { FeedbackDialog } from "../feedback/feedback-dialog";
import { isMember } from "../lib/is-member";
import { settingsTo } from "../settings/settings-hash";
import type { ThemeChoice } from "../theme/storage";
import { useTheme } from "../theme/theme-provider";

// One avatar dropdown for both auth modes — the auth adapter exposes email,
// avatar, and logout regardless of provider, so Clerk's own UserButton isn't
// needed here. Account management still lives under /settings (Settings →
// Account). Clerk supplies a generated imageUrl; local auth falls back to the
// email initial. Theme picker folded in here as radio rows so the rail's
// 32px-button slot doesn't need a second control.
const THEME_OPTIONS: ReadonlyArray<{ value: ThemeChoice; label: MsgKey; Icon: typeof Sun }> = [
	{ value: "light", label: msg("Light"), Icon: Sun },
	{ value: "dark", label: msg("Dark"), Icon: Moon },
	{ value: "system", label: msg("System"), Icon: Monitor },
];

// Radix hands onValueChange a bare string; check it against the rendered list.
const THEME_KEYS: readonly ThemeChoice[] = THEME_OPTIONS.map((o) => o.value);

// Where the plan pill goes. The desktop rail is a 48px column, so the pill
// stacks under the avatar and truncates long (translated) names; the mobile
// drawer row has room, so it sits beside the avatar at full length. Either
// way it never overlaps the avatar: two touching targets invite mis-taps.
type PlanPlacement = "below" | "beside";

// Width only: height and radius come from the shared size variants. The
// Button's `sm` size is 28px tall, clearing the WCAG 2.2 24x24px target
// minimum (2.5.8); the rail caps the width so long names truncate.
const PILL_WIDTH: Record<PlanPlacement, string> = {
	below: "max-w-11 px-1.5",
	beside: "",
};

// The paid label is not a target, so in the 48px rail it trades padding and a
// point of type for width: "Starter" fits whole (it truncated at the Button's
// sizing). Long translations still truncate, with the full name in the title.
const PAID_LABEL_WIDTH: Record<PlanPlacement, string> = {
	below: "max-w-[46px] px-0.5 text-[11px]",
	beside: "",
};

// The plan to show, or null when there is nothing to show: self-host (no
// billing, though the backend still says "free") or status not loaded yet.
function usePlan(): { name: MsgKey; tier: "free" | "starter" | "pro" } | null {
	const { billingEnabled } = useConfig();
	const { data } = useBillingStatus();
	if (!(billingEnabled && data)) {
		return null;
	}
	if (data.tier === "free") {
		return { name: FREE_TIER.name, tier: "free" };
	}
	// A tier this build does not know (a newer backend, a partial payload)
	// shows no pill rather than crashing the rail it renders in.
	return isMember(Object.keys(PLAN_CATALOG), data.tier)
		? { name: PLAN_CATALOG[data.tier].name, tier: data.tier }
		: null;
}

export default function UserMenu({ planPlacement = "below" }: { planPlacement?: PlanPlacement }) {
	const { user, logout } = useAuthAdapter();
	const { t } = useT();
	const { theme, setTheme } = useTheme();
	const location = useLocation();
	const initial = user?.email?.[0]?.toUpperCase() ?? "?";
	const [feedbackOpen, setFeedbackOpen] = useState(false);
	// Feedback goes to the hosted service's analytics; a self-hosted server
	// (billing off) has none, so the form would thank the user for nothing.
	const { billingEnabled } = useConfig();
	// Free users otherwise only meet paid plans at a paywall or in Settings.
	// The badge says which plan you are on; on Free it is also a one-click way
	// to the paid plans. The menu's Upgrade item shows on every plan below Pro,
	// the top one: Starter users can still move up.
	const plan = usePlan();
	const planName = plan?.name ?? null;
	const isFree = plan?.tier === "free";
	const canUpgrade = plan !== null && plan.tier !== "pro";
	const openBilling = useOpenBilling("user_menu");
	const openBillingFromBadge = useOpenBilling("plan_badge");

	const pillName = planName ? t(planName) : "";
	const planPill = planName ? (
		isFree ? (
			// Label-in-name: the accessible name starts with the visible plan name.
			<Button
				type="button"
				variant="outline"
				data-testid="plan-badge"
				aria-label={`${t("{plan} plan", { plan: pillName })}: ${t("See paid plans")}`}
				title={t("See paid plans")}
				onClick={openBillingFromBadge}
				size="sm"
				className={PILL_WIDTH[planPlacement]}
			>
				<span className="truncate">{pillName}</span>
			</Button>
		) : (
			<Badge
				variant="outline"
				data-testid="plan-badge"
				title={t("{plan} plan", { plan: pillName })}
				className={PAID_LABEL_WIDTH[planPlacement]}
			>
				<span className="truncate">{pillName}</span>
			</Badge>
		)
	) : null;

	return (
		<>
			{/* The pill is a sibling of the trigger, not inside it: on Free it is its
			    own button, and a button cannot nest inside the trigger button. DOM
			    order follows visual order so focus order matches what you see. */}
			<span
				className={
					planPlacement === "below"
						? "flex flex-col items-center gap-1.5"
						: "flex items-center gap-2"
				}
			>
				{planPlacement === "beside" ? planPill : null}
				<DropdownMenu>
					<DropdownMenuTrigger
						aria-label={t("User menu")}
						className="rounded-full outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background"
					>
						{user?.imageUrl ? (
							<img src={user.imageUrl} alt="" className="size-9 rounded-full object-cover" />
						) : (
							<span className="flex size-9 items-center justify-center rounded-full bg-primary font-medium text-primary-foreground text-xs">
								{initial}
							</span>
						)}
					</DropdownMenuTrigger>
					<DropdownMenuContent align="end" side="right" className="w-64 p-1.5">
						<DropdownMenuLabel className="px-3 py-2 font-normal text-muted-foreground text-sm">
							<span className="block truncate">{user?.email}</span>
							{planName ? (
								<span className="block text-xs">{t("{plan} plan", { plan: t(planName) })}</span>
							) : null}
						</DropdownMenuLabel>
						<DropdownMenuSeparator />
						{canUpgrade ? (
							<DropdownMenuItem
								className="gap-2.5 px-3 py-2.5 font-medium text-primary text-sm"
								onSelect={openBilling}
							>
								<Sparkles className="size-4" />
								{t("Upgrade")}
							</DropdownMenuItem>
						) : null}
						<DropdownMenuItem asChild className="gap-2.5 px-3 py-2.5 text-sm">
							<Link to={settingsTo("account", location.search)}>
								<Settings className="size-4" />
								{t("Settings")}
							</Link>
						</DropdownMenuItem>
						{billingEnabled ? (
							<DropdownMenuItem
								className="gap-2.5 px-3 py-2.5 text-sm"
								onSelect={() => setFeedbackOpen(true)}
							>
								<MessageSquare className="size-4" />
								{t("Send feedback")}
							</DropdownMenuItem>
						) : null}
						<DropdownMenuSeparator />
						<DropdownMenuLabel className="px-3 pt-2 pb-1 text-muted-foreground text-xs uppercase tracking-wide">
							{t("Theme")}
						</DropdownMenuLabel>
						<DropdownMenuRadioGroup
							value={theme}
							onValueChange={(v) => {
								if (isMember(THEME_KEYS, v)) {
									setTheme(v);
								}
							}}
						>
							{THEME_OPTIONS.map(({ value, label, Icon }) => (
								<DropdownMenuRadioItem
									key={value}
									value={value}
									className="gap-2.5 px-3 py-2 text-sm"
								>
									<Icon className="size-4" />
									{t(label)}
								</DropdownMenuRadioItem>
							))}
						</DropdownMenuRadioGroup>
						<DropdownMenuSeparator />
						<DropdownMenuItem
							className="gap-2.5 px-3 py-2.5 text-sm"
							onSelect={() => {
								logout();
							}}
						>
							<LogOut className="size-4" />
							{t("Sign out")}
						</DropdownMenuItem>
					</DropdownMenuContent>
				</DropdownMenu>
				{planPlacement === "below" ? planPill : null}
			</span>
			{/* Mounted only while open: no idle mutation hook on every page. */}
			{feedbackOpen ? <FeedbackDialog open onOpenChange={setFeedbackOpen} /> : null}
		</>
	);
}
