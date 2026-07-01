import { LogOut, Monitor, Moon, Settings, Sun } from "lucide-react";
import { Link } from "react-router";
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
import { useAuthAdapter } from "../auth/use-auth-adapter";
import type { ThemeChoice } from "../theme/storage";
import { useTheme } from "../theme/theme-provider";

// One avatar dropdown for both auth modes — the auth adapter exposes email,
// avatar, and logout regardless of provider, so Clerk's own UserButton isn't
// needed here. Account management still lives under /settings (Settings →
// Account). Clerk supplies a generated imageUrl; local auth falls back to the
// email initial. Theme picker folded in here as radio rows so the rail's
// 32px-button slot doesn't need a second control.
const THEME_OPTIONS: ReadonlyArray<{ value: ThemeChoice; label: string; Icon: typeof Sun }> = [
	{ value: "light", label: "Light", Icon: Sun },
	{ value: "dark", label: "Dark", Icon: Moon },
	{ value: "system", label: "System", Icon: Monitor },
];

export default function UserMenu() {
	const { user, logout } = useAuthAdapter();
	const { theme, setTheme } = useTheme();
	const initial = user?.email?.[0]?.toUpperCase() ?? "?";

	return (
		<DropdownMenu>
			<DropdownMenuTrigger
				aria-label="User menu"
				data-tour="settings-link"
				className="rounded-full outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background"
			>
				{user?.imageUrl ? (
					<img src={user.imageUrl} alt="" className="h-9 w-9 rounded-full object-cover" />
				) : (
					<span className="flex h-9 w-9 items-center justify-center rounded-full bg-primary text-xs font-medium text-primary-foreground">
						{initial}
					</span>
				)}
			</DropdownMenuTrigger>
			<DropdownMenuContent align="end" side="right" className="w-64 p-1.5">
				<DropdownMenuLabel className="truncate px-3 py-2 text-sm font-normal text-muted-foreground">
					{user?.email}
				</DropdownMenuLabel>
				<DropdownMenuSeparator />
				<DropdownMenuItem asChild className="gap-2.5 px-3 py-2.5 text-sm">
					<Link to="/settings">
						<Settings className="h-4 w-4" />
						Settings
					</Link>
				</DropdownMenuItem>
				<DropdownMenuSeparator />
				<DropdownMenuLabel className="px-3 pb-1 pt-2 text-xs uppercase tracking-wide text-muted-foreground">
					Theme
				</DropdownMenuLabel>
				<DropdownMenuRadioGroup value={theme} onValueChange={(v) => setTheme(v as ThemeChoice)}>
					{THEME_OPTIONS.map(({ value, label, Icon }) => (
						<DropdownMenuRadioItem key={value} value={value} className="gap-2.5 px-3 py-2 text-sm">
							<Icon className="h-4 w-4" />
							{label}
						</DropdownMenuRadioItem>
					))}
				</DropdownMenuRadioGroup>
				<DropdownMenuSeparator />
				<DropdownMenuItem className="gap-2.5 px-3 py-2.5 text-sm" onSelect={() => void logout()}>
					<LogOut className="h-4 w-4" />
					Sign out
				</DropdownMenuItem>
			</DropdownMenuContent>
		</DropdownMenu>
	);
}
