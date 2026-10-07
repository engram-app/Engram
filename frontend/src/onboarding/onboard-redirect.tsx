import { Navigate } from "react-router";
import { useT } from "@/i18n/locale-provider";
import { useOnboardingStatus } from "../api/queries";
import { onboardingNext } from "./onboarding-next";

export default function OnboardRedirect() {
	const { t } = useT();
	const { data, isLoading } = useOnboardingStatus();
	if (isLoading || !data) {
		return <p>{t("Loading...")}</p>;
	}
	return <Navigate to={onboardingNext(data)} replace />;
}
