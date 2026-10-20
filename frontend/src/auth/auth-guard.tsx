import { lazy, Suspense } from "react";
import { Navigate, Outlet, useLocation } from "react-router";
import LoadingScreen from "../layout/loading-screen";
import { signInRedirectTarget } from "./sign-in-redirect";
import { useAuthAdapter } from "./use-auth-adapter";

// Lazy: AuthGuard is in the eager sign-in bundle, and the reporter pulls in
// react-query + the API client. The bundle budget gate fails on a static import.
const ReportLocale = lazy(() =>
	import("../i18n/report-locale").then((m) => ({ default: m.ReportLocale })),
);
// Lazy for the same reason: it opens a socket and reads /me.
const ConnectionCreatedNotice = lazy(() =>
	import("../oauth/connection-created-notice").then((m) => ({
		default: m.ConnectionCreatedNotice,
	})),
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
			<Suspense fallback={null}>
				<ConnectionCreatedNotice />
			</Suspense>
			<Outlet />
		</>
	);
}
