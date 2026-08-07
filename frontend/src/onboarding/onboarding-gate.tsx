import { Navigate, Outlet } from "react-router";
import { useAppBootstrap, useOnboardingStatus } from "../api/queries";
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

	if (isLoading || !data || !onboarding) {
		return <LoadingScreen />;
	}

	if (!onboarding.enabled || onboarding.next_step === "done") {
		return <Outlet />;
	}

	return <Navigate to={`/onboard/${onboarding.next_step}`} replace />;
}
