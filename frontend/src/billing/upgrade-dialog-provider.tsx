import type { ReactNode } from "react";
import { createContext, lazy, Suspense, useCallback, useContext, useEffect, useState } from "react";

import { setUpgradeHandler } from "@/api/client";

// Lazy: the provider mounts at the router root (so it wraps the sign-in page
// too), but the dialog itself only renders after a 402 — no reason for its
// radix-dialog + billing-copy weight to sit in the eager entry bundle.
const UpgradeRequiredDialog = lazy(() =>
	import("./upgrade-required-dialog").then((m) => ({ default: m.UpgradeRequiredDialog })),
);

interface Ctx {
	showUpgrade: (reason: string) => void;
}
const UpgradeCtx = createContext<Ctx | null>(null);

export function UpgradeDialogProvider({ children }: { children: ReactNode }) {
	const [reason, setReason] = useState<string | null>(null);

	const showUpgrade = useCallback((next: string) => setReason(next), []);

	// Wire the module-level handler in the API client so 402 responses surface
	// the dialog automatically. Cleared on unmount so a stale closure doesn't
	// leak between provider remounts (StrictMode, HMR, tests).
	useEffect(() => {
		setUpgradeHandler(showUpgrade);
		return () => setUpgradeHandler(null);
	}, [showUpgrade]);

	return (
		<UpgradeCtx.Provider value={{ showUpgrade }}>
			{children}
			{reason ? (
				<Suspense fallback={null}>
					<UpgradeRequiredDialog
						reason={reason}
						open={true}
						onOpenChange={(open) => {
							if (!open) {
								setReason(null);
							}
						}}
					/>
				</Suspense>
			) : null}
		</UpgradeCtx.Provider>
	);
}

export function useUpgradeDialog(): Ctx {
	const ctx = useContext(UpgradeCtx);
	if (!ctx) {
		throw new Error("useUpgradeDialog called outside UpgradeDialogProvider");
	}
	return ctx;
}
