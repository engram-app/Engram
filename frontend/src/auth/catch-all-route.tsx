import { Navigate, useLocation } from "react-router";
import LoadingScreen from "../layout/loading-screen";
import NotFoundPage from "../not-found";
import { signInRedirectTarget } from "./sign-in-redirect";
import { useAuthAdapter } from "./use-auth-adapter";

// Auth-aware catch-all for unmatched paths.
//
// A signed-out visitor hitting any unknown URL is bounced to sign-in
// (with the attempted path as return_to) rather than shown a dead-end 404 —
// there is nothing for them to do on a 404 until they authenticate anyway.
// Signed-in users still get the real 404; a typo for them is just a typo,
// not a reason to round-trip through auth.
export default function CatchAllRoute() {
	const { isLoaded, isSignedIn } = useAuthAdapter();
	const location = useLocation();

	if (!isLoaded) {
		return <LoadingScreen />;
	}

	if (!isSignedIn) {
		return <Navigate to={signInRedirectTarget(location)} replace />;
	}

	return <NotFoundPage />;
}
