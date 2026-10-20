import { lazy, Suspense } from "react";
import { Navigate, Outlet, useLocation } from "react-router";
import { whenLoaded } from "@/lib/when-loaded";
import LoadingScreen from "../layout/loading-screen";
import { signInRedirectTarget } from "./sign-in-redirect";
import { useAuthAdapter } from "./use-auth-adapter";

// Lazy: AuthGuard is in the eager sign-in bundle, and the reporter pulls in
// react-query + the API client. The bundle budget gate fails on a static import.
const ReportLocale = lazy(() =>
	whenLoaded(import("../i18n/report-locale")).then((m) => ({ default: m.ReportLocale })),
);

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
			<Suspense fallback={null}>
				<ReportLocale />
			</Suspense>
			<Outlet />
		</>
	);
}
