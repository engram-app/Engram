import { Navigate, Outlet, useLocation } from "react-router";
import { type OnboardingStep, useOnboardingStatus } from "../api/queries";
import { useAuthAdapter } from "../auth/use-auth-adapter";
import AuthShell from "../layout/auth-shell";
import LoadingScreen from "../layout/loading-screen";

const STEP_PATHS: OnboardingStep[] = ["agreement", "billing", "tools", "vault"];

function stepFromPath(pathname: string): OnboardingStep | null {
	const last = pathname.split("/").pop() ?? "";
	return (STEP_PATHS as readonly string[]).includes(last) ? (last as OnboardingStep) : null;
}

export default function OnboardLayout() {
	const { logout } = useAuthAdapter();
	const { pathname } = useLocation();
	const { data, isLoading } = useOnboardingStatus();

	if (isLoading || !data) return <LoadingScreen />;

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

	return (
		<AuthShell
			navLabel="Onboarding"
			actions={
				<>
					{counter ? <p className="text-sm text-muted-foreground">{counter}</p> : null}
					<button
						type="button"
						onClick={() => logout()}
						className="text-sm text-muted-foreground transition hover:text-foreground"
					>
						Sign out
					</button>
				</>
			}
		>
			<Outlet />
		</AuthShell>
	);
}
