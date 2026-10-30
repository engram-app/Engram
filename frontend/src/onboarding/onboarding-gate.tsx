import { useQueryClient } from "@tanstack/react-query";
import { useEffect } from "react";
import { Navigate, Outlet } from "react-router";
import { getActiveVaultId } from "../api/active-vault";
import { useAppBootstrap, useOnboardingStatus } from "../api/queries";
import { prefetchFirstView } from "../layout/first-view";
import LoadingScreen from "../layout/loading-screen";

export default function OnboardingGate() {
	// Single first-load fetch: resolves onboarding state AND seeds the billing /
	// vaults / capabilities caches, so the views mounted past this gate read from
	// cache instead of each issuing their own request.
	const { data, isLoading } = useAppBootstrap();
	// Route off the granular ["onboarding","status"] cache — the one every
	// wizard mutation invalidates — never bootstrap's own copy, which is cached
	// forever and once looped finished users back to /onboard/agreement.
	// `enabled` waits for the bootstrap seed so first load stays one request.
	const { data: onboarding } = useOnboardingStatus({ enabled: data !== undefined });
	const open = onboarding !== undefined && (!onboarding.enabled || onboarding.next_step === "done");
	// The tree, the note and its code, before this gate's children mount
	// (first-view.ts). Only once the gate is open: the vault routes 403 an
	// unfinished signup, and firing this on mount, before the status was known,
	// was most of prod's "onboarding refused" lines.
	const qc = useQueryClient();
	useEffect(() => {
		if (open) {
			prefetchFirstView(qc, window.location.pathname, getActiveVaultId());
		}
	}, [qc, open]);

	if (isLoading || !data || !onboarding) {
		return <LoadingScreen />;
	}

	if (open) {
		return <Outlet />;
	}

	return <Navigate to={`/onboard/${onboarding.next_step}`} replace />;
}
