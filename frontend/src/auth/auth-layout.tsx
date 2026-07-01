import type { ReactNode } from "react";
import AuthBackdrop from "../layout/auth-backdrop";

export default function AuthLayout({ children }: { children: ReactNode }) {
	return (
		<main className="relative flex min-h-dvh items-center justify-center overflow-hidden bg-background text-foreground">
			<AuthBackdrop />
			<div className="relative z-10 flex w-full items-center justify-center px-4 py-12">
				{children}
			</div>
		</main>
	);
}
