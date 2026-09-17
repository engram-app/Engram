import { Navigate } from "react-router";
import { useOnboardingStatus } from "../api/queries";
import { onboardingNext } from "./onboarding-next";

export default function OnboardRedirect() {
	const { data, isLoading } = useOnboardingStatus();
	if (isLoading || !data) {
		return <p>Loading...</p>;
	}
	return <Navigate to={onboardingNext(data)} replace />;
}
