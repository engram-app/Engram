import type { ReactNode } from "react";
import { LanguageSelect } from "../i18n/language-select";
import ThemeToggle from "../theme/theme-toggle";
import AuthBackdrop from "./auth-backdrop";

interface AuthShellProps {
	actions?: ReactNode;
	navLabel?: string;
	/** A status strip shown as a second row of the top bar. It lives in the
	 *  header, not the scroll area, because step pages size themselves to
	 *  `max-h-full` of that area and anything stacked above them overflows. */
	notice?: ReactNode;
	children: ReactNode;
}

export default function AuthShell({ actions, navLabel, notice, children }: AuthShellProps) {
	return (
		<main className="flex h-dvh flex-col bg-background text-foreground">
			<header className="flex flex-wrap items-center justify-between gap-y-2 border-border border-b bg-card px-4 py-2">
				<span className="flex items-center gap-2 font-semibold text-foreground text-lg">
					<img src="/engram-mark.svg" alt="" className="size-6" />
					Engram
				</span>
				<nav className="flex items-center gap-3" aria-label={navLabel}>
					{actions}
					<LanguageSelect iconOnly />
					<ThemeToggle />
				</nav>
				{notice ? (
					<aside
						role="status"
						className="flex basis-full flex-wrap items-center justify-between gap-x-3 gap-y-1 border-border border-t pt-2 text-sm"
					>
						{notice}
					</aside>
				) : null}
			</header>
			<section className="relative flex min-h-0 flex-1 flex-col overflow-hidden">
				<AuthBackdrop />
				<div className="relative z-10 flex min-h-0 flex-1 flex-col overflow-y-auto">{children}</div>
			</section>
		</main>
	);
}
