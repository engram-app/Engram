import { LogOut, MessageSquare, Monitor, Moon, Settings, Sparkles, Sun } from "lucide-react";
import { useState } from "react";
import { Link, useLocation } from "react-router";
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
import { useAuthAdapter } from "../auth/use-auth-adapter";
import { useOpenBilling } from "../billing/use-open-billing";
import { usePlan } from "../billing/use-plan";
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

export default function UserMenu() {
	const { user, logout } = useAuthAdapter();
	const { t } = useT();
	const { theme, setTheme } = useTheme();
	const location = useLocation();
	const initial = user?.email?.[0]?.toUpperCase() ?? "?";
	const [feedbackOpen, setFeedbackOpen] = useState(false);
	// Feedback goes to the hosted service's analytics; a self-hosted server
	// (billing off) has none, so the form would thank the user for nothing.
	const { billingEnabled } = useConfig();
	// The menu names your plan under the email and offers Upgrade on every plan
	// below Pro, the top one: Starter users can still move up.
	const plan = usePlan();
	const planName = plan?.name ?? null;
	const canUpgrade = plan !== null && plan.tier !== "pro";
	const openBilling = useOpenBilling("user_menu");

	return (
		<>
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
			{/* Mounted only while open: no idle mutation hook on every page. */}
			{feedbackOpen ? <FeedbackDialog open onOpenChange={setFeedbackOpen} /> : null}
		</>
	);
}
