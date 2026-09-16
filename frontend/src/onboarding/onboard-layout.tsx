import { Navigate, Outlet, useLocation } from "react-router";
import { type OnboardingStep, useOnboardingStatus } from "../api/queries";
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

	if (isLoading || !data) {
		return <LoadingScreen />;
	}

	const current = stepFromPath(pathname);
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

	const cancelPending = () => {
		// Read the destination BEFORE clearing: it is derived from the parked
		// request.
		const url = pendingCancelUrl();
		clearPendingAuthorization();
		if (url) {
			window.location.assign(url);
		}
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
					<button
						type="button"
						onClick={cancelPending}
						className="text-muted-foreground underline underline-offset-4 transition hover:text-foreground"
					>
						Cancel connection
					</button>
				</aside>
			) : null}
			<Outlet />
		</AuthShell>
	);
}
