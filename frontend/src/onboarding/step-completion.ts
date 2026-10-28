import type { OnboardingStep } from "../api/queries";

/** Steps finished this page load. A reload or redirect right after a step's
 *  submit fires pagehide while that step is still mounted; without this it
 *  would be reported as abandoned (onboard-layout.tsx). */
const completed = new Set<OnboardingStep>();

export function markStepCompleted(step: OnboardingStep): void {
	completed.add(step);
}

export function isStepCompleted(step: OnboardingStep): boolean {
	return completed.has(step);
}
