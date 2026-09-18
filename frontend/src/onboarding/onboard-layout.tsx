import { useEffect } from "react";
import { Navigate, Outlet, useLocation } from "react-router";
import { type OnboardingStep, useOnboardingStatus } from "../api/queries";
import { track } from "../analytics/track";
import { useAuthAdapter } from "../auth/use-auth-adapter";
import AuthShell from "../layout/auth-shell";
import LoadingScreen from "../layout/loading-screen";
import { isMember } from "../lib/is-member";
import {
	clearPendingAuthorization,
	peekPendingAuthorization,
	pendingCancelUrl,
} from "../oauth/pending-authorization";

const STEP_PATHS: OnboardingStep[] = ["agreement", "billing", "tools", "vault"];

function stepFromPath(pathname: string): OnboardingStep | null {
	const last = pathname.split("/").pop() ?? "";
	return isMember(STEP_PATHS, last) ? last : null;
}

export default function OnboardLayout() {
	const { logout } = useAuthAdapter();
	const { pathname } = useLocation();
	const { data, isLoading } = useOnboardingStatus();

	// Computed unconditionally (Hooks can't follow the loading early-return
	// below), so the effect beneath it can be called unconditionally too.
	const current = stepFromPath(pathname);

	// Fires once per distinct step, not once per onboarding/status refetch —
	// this is the signal that would have shown someone stuck on one step
	// across two visits, so it must key on the step alone, not on query churn.
	// biome-ignore lint/correctness/useExhaustiveDependencies: deliberately
	// keyed on `current` only — see comment above.
	useEffect(() => {
		if (!current || isLoading || !data || !data.steps.includes(current)) {
			return;
		}
		track("onboarding_step_viewed", { step: current });
	}, [current]);

	if (isLoading || !data) {
		return <LoadingScreen />;
	}

	// Step not in the active chain for this account (e.g. /onboard/agreement on
	// self-host, or /onboard/billing after billing is satisfied) — punt to the
	// resolver, which sends them to next_step.
	if (current && !data.steps.includes(current)) {
		return <Navigate to="/onboard" replace />;
	}

	const index = current ? data.steps.indexOf(current) : -1;
	const total = data.steps.length;
	const counter = index >= 0 ? `Step ${index + 1} of ${total}` : null;

	// Someone pulled in here mid-OAuth is not doing a normal signup, and a
	// wizard that says nothing about it reads like the connection silently
	// failed. Naming the app, and offering a refusal the app actually hears,
	// is what keeps an interrupted authorization legible.
	const pending = peekPendingAuthorization();

	// Derived from the parked request, so it must be read before anything
	// clears it. Null means the refusal has nowhere to go.
	const cancelUrl = pendingCancelUrl();

	const cancelPending = () => {
		if (!cancelUrl) {
			return;
		}
		// Clear only once the refusal is actually deliverable. Clearing
		// unconditionally ALSO dropped the parked request, so a user whose
		// client had no usable redirect got a button that did nothing and then
		// finished the wizard onto `/` instead of back to consent.
		clearPendingAuthorization();
		window.location.assign(cancelUrl);
	};

	return (
		<AuthShell
			navLabel="Onboarding"
			actions={
				<>
					{counter ? <p className="text-muted-foreground text-sm">{counter}</p> : null}
					<button
						type="button"
						onClick={() => logout()}
						className="text-muted-foreground text-sm transition hover:text-foreground"
					>
						Sign out
					</button>
				</>
			}
		>
			{pending ? (
				<aside
					role="status"
					className="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-md border border-border bg-muted/40 p-3 text-sm"
				>
					<p className="text-muted-foreground">
						Finish setting up to connect{" "}
						<span className="font-medium text-foreground">
							{pending.clientName ?? "the app that sent you here"}
						</span>
						.
					</p>
					{/* Rendered only when the refusal can actually be delivered.
					    A button that silently no-ops reads as a broken app. */}
					{cancelUrl ? (
						<button
							type="button"
							onClick={cancelPending}
							className="text-muted-foreground underline underline-offset-4 transition hover:text-foreground"
						>
							Cancel connection
						</button>
					) : null}
				</aside>
			) : null}
			<Outlet />
		</AuthShell>
	);
}
