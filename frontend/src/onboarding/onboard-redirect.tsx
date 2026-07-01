import { Navigate } from "react-router";
import { useOnboardingStatus } from "../api/queries";

export default function OnboardRedirect() {
	const { data, isLoading } = useOnboardingStatus();
	if (isLoading || !data) return <p>Loading...</p>;
	return <Navigate to={data.next_step === "done" ? "/" : `/onboard/${data.next_step}`} replace />;
}
