import { useEffect, useRef } from "react";
import { setPersonProperties } from "../analytics/identity";
import { ApiError } from "../api/client";
import { useMe, useUpdateProfile } from "../api/queries";
import { useT } from "./locale-provider";

// A 4xx (other than 429) is a verdict on the tag: retrying cannot change it.
function retryTransient(failureCount: number, error: Error): boolean {
	const permanent = error instanceof ApiError && error.status < 500 && error.status !== 429;
	return !permanent && failureCount < 2;
}

// Records the user's UI language on the account (`users.locale`) and as a PostHog
// person property, so the backend can localize email later (#1943) and analytics
// can segment by language. Reports the CHOSEN locale, not `renderedLocale`, which
// reads "en" until the catalog chunk lands.
export function useReportLocale(): void {
	const { locale } = useT();
	const { data: me } = useMe();
	const { mutate } = useUpdateProfile({ retry: retryTransient });
	// One attempt (plus bounded transient retries) per locale per session: a
	// failing PATCH must not loop.
	const attempted = useRef<string | null>(null);

	useEffect(() => {
		if (!me || me.locale === locale || attempted.current === locale) {
			return;
		}
		attempted.current = locale;
		mutate({ locale });
	}, [me, locale, mutate]);

	const userId = me?.id;
	const optedOut = me?.analytics_opt_out;
	useEffect(() => {
		if (userId && optedOut === false) {
			setPersonProperties({ locale });
		}
	}, [userId, optedOut, locale]);
}
