import posthog from "posthog-js";
import { useEffect, useRef } from "react";
import { useMe, useUpdateProfile } from "../api/queries";
import { useT } from "./locale-provider";

// Records the user's UI language on the account (`users.locale`) and as a PostHog
// person property, so the backend can localize email later (#1943) and analytics
// can segment by language. Reports the CHOSEN locale, not `renderedLocale`, which
// reads "en" until the catalog chunk lands.
export function useReportLocale(): void {
	const { locale } = useT();
	const { data: me } = useMe();
	const { mutate } = useUpdateProfile();
	// One attempt per locale per session: a failing PATCH must not loop.
	const attempted = useRef<string | null>(null);

	useEffect(() => {
		if (!me || me.locale === locale || attempted.current === locale) {
			return;
		}
		attempted.current = locale;
		mutate({ locale });
	}, [me, locale, mutate]);

	useEffect(() => {
		if (me) {
			posthog.setPersonProperties({ locale });
		}
	}, [me, locale]);
}
