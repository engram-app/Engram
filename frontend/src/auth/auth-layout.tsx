import type { ReactNode } from "react";
import { LanguageSelect } from "../i18n/language-select";
import AuthBackdrop from "../layout/auth-backdrop";

export default function AuthLayout({ children }: { children: ReactNode }) {
	return (
		<main className="relative flex min-h-dvh items-center justify-center overflow-hidden bg-background text-foreground">
			<AuthBackdrop />
			<div className="absolute top-4 right-4 z-20">
				<LanguageSelect iconOnly />
			</div>
			<div className="relative z-10 flex w-full items-center justify-center px-4 py-12">
				{children}
			</div>
		</main>
	);
}
