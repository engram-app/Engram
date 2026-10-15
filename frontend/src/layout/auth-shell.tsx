import type { ReactNode } from "react";
import { LanguageSelect } from "../i18n/language-select";
import ThemeToggle from "../theme/theme-toggle";
import AuthBackdrop from "./auth-backdrop";

interface AuthShellProps {
	actions?: ReactNode;
	navLabel?: string;
	/** A status item in the middle of the top bar. It lives in the header, not
	 *  the scroll area, because step pages size themselves to `max-h-full` of
	 *  that area and anything stacked above them overflows. One row only: keep
	 *  it short, it truncates on narrow screens. */
	notice?: ReactNode;
	children: ReactNode;
}

export default function AuthShell({ actions, navLabel, notice, children }: AuthShellProps) {
	return (
		<main className="flex h-dvh flex-col bg-background text-foreground">
			<header className="flex items-center justify-between gap-3 border-border border-b bg-card px-4 py-2">
				<span className="flex shrink-0 items-center gap-2 font-semibold text-foreground text-lg">
					<img src="/engram-mark.svg" alt="" className="size-6" />
					{/* ponytail: on phones a notice needs the wordmark's width; the mark stays. */}
					<span className={notice ? "sr-only sm:not-sr-only" : undefined}>Engram</span>
				</span>
				{notice ? (
					<aside
						role="status"
						className="flex min-w-0 flex-1 items-center justify-center gap-1 whitespace-nowrap text-muted-foreground text-sm"
					>
						{notice}
					</aside>
				) : null}
				<nav
					className={
						notice
							? "flex shrink-0 items-center gap-1 sm:gap-3"
							: "flex shrink-0 items-center gap-3"
					}
					aria-label={navLabel}
				>
					{actions}
					<LanguageSelect iconOnly />
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
