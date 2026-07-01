import { Navigate, Outlet } from "react-router";
import { useAppBootstrap } from "../api/queries";
import LoadingScreen from "../layout/loading-screen";

export default function OnboardingGate() {
	// Single first-load fetch: resolves onboarding state AND seeds the billing /
	// vaults / capabilities caches, so the views mounted past this gate read from
	// cache instead of each issuing their own request.
	const { data, isLoading } = useAppBootstrap();

	if (isLoading || !data) {
		return <LoadingScreen />;
	}

	const onboarding = data.onboarding;

	if (!onboarding.enabled || onboarding.next_step === "done") {
		return <Outlet />;
	}

	return <Navigate to={`/onboard/${onboarding.next_step}`} replace />;
}
