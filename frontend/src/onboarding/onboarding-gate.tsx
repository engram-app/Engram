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
	// Same tick as /bootstrap: the tree, the note and its code, in parallel
	// rather than waiting for this gate to render its children (first-view.ts).
	const qc = useQueryClient();
	useEffect(() => {
		// ponytail: fires before the onboarding status is known, on purpose. For
		// a signup still in the wizard the vault routes 403 it: one harmless
		// refused burst, which the refusal line's route + surface identify
		// (`VaultTreeController#show`, `web`). Waiting for the status instead
		// costs every onboarded cold load a /bootstrap round trip.
		prefetchFirstView(qc, window.location.pathname, getActiveVaultId());
	}, [qc]);
	// Route off the granular ["onboarding","status"] cache — the one every
	// wizard mutation invalidates — never bootstrap's own copy, which is cached
	// forever and once looped finished users back to /onboard/agreement.
	// `enabled` waits for the bootstrap seed so first load stays one request.
	const { data: onboarding } = useOnboardingStatus({ enabled: data !== undefined });

	if (isLoading || !data || !onboarding) {
		return <LoadingScreen />;
	}

	if (!onboarding.enabled || onboarding.next_step === "done") {
		return <Outlet />;
	}

	return <Navigate to={`/onboard/${onboarding.next_step}`} replace />;
}
