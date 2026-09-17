import { lazy, Suspense } from "react";
import { useSearchParams } from "react-router";
import { useConfig } from "../config-context";
import AuthLayout from "./auth-layout";
import { safeReturnTo } from "./safe-return-to";

// Both lazy refs are declared at module scope so React preserves the lazy
// component identity across renders. Mirrors sign-in.tsx.
const ClerkSignUp = lazy(() => import("./clerk-sign-up"));
const LocalSignUp = lazy(() => import("./local-sign-up"));

export default function SignUpPage() {
	const [searchParams] = useSearchParams();
	const returnTo = safeReturnTo(searchParams.get("return_to"));
	const config = useConfig();

	if (config.authProvider === "clerk") {
		return (
			<AuthLayout>
				<Suspense fallback={<p>Loading...</p>}>
					<ClerkSignUp returnTo={returnTo} />
				</Suspense>
			</AuthLayout>
		);
	}

	return (
		<Suspense fallback={<p>Loading...</p>}>
			<LocalSignUp />
		</Suspense>
	);
}
