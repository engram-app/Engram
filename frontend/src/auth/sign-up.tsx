import { lazy, Suspense, useEffect } from "react";
import { useSearchParams } from "react-router";
import { useT } from "@/i18n/locale-provider";
import { whenLoaded } from "@/lib/when-loaded";
import { captureSignupAttribution } from "../analytics/attribution";
import { useConfig } from "../config-context";
import AuthLayout from "./auth-layout";
import { safeReturnTo } from "./safe-return-to";

// Both lazy refs are declared at module scope so React preserves the lazy
// component identity across renders. Mirrors sign-in.tsx.
const ClerkSignUp = lazy(() => whenLoaded(import("./clerk-sign-up")));
const LocalSignUp = lazy(() => whenLoaded(import("./local-sign-up")));

export default function SignUpPage() {
	const { t } = useT();
	const [searchParams] = useSearchParams();
	const returnTo = safeReturnTo(searchParams.get("return_to"));
	const config = useConfig();

	// Before Clerk takes over the page: the marketing site's `?via=`/`utm_*`
	// and the referrer are only here on the first render.
	useEffect(() => {
		captureSignupAttribution(window.location.search, document.referrer, window.location.hostname);
	}, []);

	if (config.authProvider === "clerk") {
		return (
			<AuthLayout>
				<Suspense fallback={<p>{t("Loading...")}</p>}>
					<ClerkSignUp returnTo={returnTo} />
				</Suspense>
			</AuthLayout>
		);
	}

	return (
		<Suspense fallback={<p>{t("Loading...")}</p>}>
			<LocalSignUp />
		</Suspense>
	);
}
