import { lazy, Suspense } from "react";
import { Navigate } from "react-router";
import { useConfig } from "../config-context";
import { ROUTES } from "../routes";
import AuthLayout from "./auth-layout";

const ClerkWaitlistPage = lazy(() =>
	import("@clerk/react").then((mod) => ({
		default: () => (
			<AuthLayout>
				<mod.Waitlist signInUrl={ROUTES.SIGN_IN} />
			</AuthLayout>
		),
	})),
);

export default function WaitlistPage() {
	const config = useConfig();
	if (config.authProvider !== "clerk" || !config.clerkWaitlistMode) {
		return <Navigate to={ROUTES.SIGN_UP} replace />;
	}

	return (
		<Suspense fallback={<p>Loading...</p>}>
			<ClerkWaitlistPage />
		</Suspense>
	);
}
