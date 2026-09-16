/**
 * Where the onboarding wizard should send someone next.
 *
 * "Done means `/`" used to be spelled out at six sites across three step
 * pages, so teaching the wizard to return a user to an interrupted OAuth
 * authorization meant finding all six. It is one rule now.
 */

import type { OnboardingStep } from "../api/queries";
import { peekPendingAuthorization } from "../oauth/pending-authorization";
import { ROUTES } from "../routes";

/** Where a FINISHED wizard lands. Home, unless the user was pulled in from a
 *  consent screen that is still waiting on them. */
export function onboardingDoneTarget(): string {
	return peekPendingAuthorization()?.returnTo ?? ROUTES.HOME;
}

/** Resolves a status into the path for its next step. A pending authorization
 *  is only consulted once every step is genuinely done — it must never
 *  short-circuit the wizard, which is the thing standing between an MCP-first
 *  signup and a grant that works. */
export function onboardingNext(status: { next_step: OnboardingStep | "done" }): string {
	return status.next_step === "done"
		? onboardingDoneTarget()
		: `/onboard/${status.next_step}`;
}
