import type { ReactNode } from "react";
import ThemeToggle from "../theme/theme-toggle";
import AuthBackdrop from "./auth-backdrop";

interface AuthShellProps {
	actions?: ReactNode;
	navLabel?: string;
	children: ReactNode;
}

export default function AuthShell({ actions, navLabel, children }: AuthShellProps) {
	return (
		<main className="flex h-dvh flex-col bg-background text-foreground">
			<header className="flex items-center justify-between border-border border-b bg-card px-4 py-2">
				<span className="flex items-center gap-2 font-semibold text-foreground text-lg">
					<img src="/engram-mark.svg" alt="" className="size-6" />
					Engram
				</span>
				<nav className="flex items-center gap-3" aria-label={navLabel}>
					{actions}
					<ThemeToggle />
				</nav>
			</header>
			<section className="relative flex min-h-0 flex-1 flex-col overflow-hidden">
				<AuthBackdrop />
				<div className="relative z-10 flex min-h-0 flex-1 flex-col overflow-y-auto">{children}</div>
			</section>
		</main>
	);
}
