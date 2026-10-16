import { Navigate, Outlet, useLocation } from "react-router";
import { ReportLocale } from "../i18n/report-locale";
import LoadingScreen from "../layout/loading-screen";
import { signInRedirectTarget } from "./sign-in-redirect";
import { useAuthAdapter } from "./use-auth-adapter";

export default function AuthGuard() {
	const { isLoaded, isSignedIn } = useAuthAdapter();
	const location = useLocation();

	if (!isLoaded) {
		return <LoadingScreen />;
	}

	if (!isSignedIn) {
		return <Navigate to={signInRedirectTarget(location)} replace />;
	}

	// The locale reporter lives here, not in AppLayout: onboarding, /link and
	// /oauth/consent sit outside the app shell, and users who stop there would
	// otherwise never have their locale recorded.
	return (
		<>
			<ReportLocale />
			<Outlet />
		</>
	);
}
