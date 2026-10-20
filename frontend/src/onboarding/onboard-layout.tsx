import { LogOut, X } from "lucide-react";
import { useEffect, useState } from "react";
import { Navigate, Outlet, useLocation } from "react-router";
import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";
import { useT } from "@/i18n/locale-provider";
import { cn } from "@/lib/utils";
import { sendSignupAttribution } from "../analytics/attribution";
import { track } from "../analytics/track";
import { type OnboardingStep, useOnboardingStatus } from "../api/queries";
import { useAuthAdapter } from "../auth/use-auth-adapter";
import AuthShell from "../layout/auth-shell";
import LoadingScreen from "../layout/loading-screen";
import { isMember } from "../lib/is-member";
import { clearPendingAuthorization, pendingCancelUrl } from "../oauth/pending-authorization";

const STEP_PATHS: OnboardingStep[] = ["agreement", "billing", "heard", "vault"];

function stepFromPath(pathname: string): OnboardingStep | null {
	const last = pathname.split("/").pop() ?? "";
	return isMember(STEP_PATHS, last) ? last : null;
}

export default function OnboardLayout() {
	const { t } = useT();
	const { logout } = useAuthAdapter();
	const { pathname } = useLocation();
	const { data, isLoading } = useOnboardingStatus();
	const [confirmCancel, setConfirmCancel] = useState(false);

	// Computed unconditionally (Hooks can't follow the loading early-return
	// below), so the effect beneath it can be called unconditionally too.
	const current = stepFromPath(pathname);

	// `/onboard` sits outside OnboardingGate's bootstrap seed, so this query is
	// genuinely uncached on a real first visit — the effect below WILL run
	// once while still loading, before it has anything to report. `ready`
	// flips false -> true exactly once (react-query's `isLoading` only covers
	// "no data yet"; a background refetch, e.g. refetchOnWindowFocus, leaves
	// it false since data already exists), which is what gives the effect its
	// second chance to fire once the query actually resolves. A boolean, not
	// `data` itself, is in the deps — `data` gets a new reference on every
	// refetch even when `steps` is unchanged, which would refire this on every
	// background revalidation.
	const ready = !isLoading && data !== undefined;

	// Every new account passes through here signed in, so this is where the
	// attribution stashed on /sign-up reaches the server (once).
	useEffect(() => {
		sendSignupAttribution();
	}, []);

	// Fires once per distinct step actually shown, not once per
	// onboarding/status refetch — this is the signal that would have shown
	// someone stuck on one step across two visits, so it must key on the step
	// (once known) alone, not on query churn.
	// biome-ignore lint/correctness/useExhaustiveDependencies: deliberately keyed on `current` + `ready` only — see comments above.
	useEffect(() => {
		if (!(current && ready && data?.steps.includes(current))) {
			return;
		}
		track("onboarding_step_viewed", { step: current });
	}, [current, ready]);

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
	const counter = index >= 0 ? t("Step {step} of {total}", { step: index + 1, total }) : null;

	// A user pulled in here mid-OAuth can refuse in a way the waiting client
	// hears. Null when the refusal has nowhere verified to go: no button then.
	// It leaves the site for good, so it asks first.
	const cancelUrl = pendingCancelUrl();
	const cancelPending = () => {
		if (cancelUrl) {
			clearPendingAuthorization();
			window.location.assign(cancelUrl);
		}
	};

	return (
		<AuthShell
			navLabel={t("Onboarding")}
			actions={
				counter ? (
					// Hidden on phones while the refusal is offered: no room for both.
					<p
						className={cn(
							"whitespace-nowrap text-muted-foreground text-sm",
							cancelUrl && "hidden sm:block",
						)}
					>
						{counter}
					</p>
				) : null
			}
			trailing={
				<>
					{cancelUrl ? (
						<Button
							type="button"
							variant="ghost"
							size="icon"
							aria-label={t("Stop connecting this app")}
							title={t("Stop connecting this app")}
							onClick={() => setConfirmCancel(true)}
						>
							<X aria-hidden="true" />
						</Button>
					) : null}
					<Button
						type="button"
						variant="ghost"
						size="icon"
						aria-label={t("Sign out")}
						title={t("Sign out")}
						onClick={() => logout()}
					>
						<LogOut aria-hidden="true" />
					</Button>
				</>
			}
		>
			<Outlet />
			<Dialog open={confirmCancel} onOpenChange={setConfirmCancel}>
				<DialogContent className="sm:max-w-md">
					<DialogHeader>
						<DialogTitle>{t("Stop connecting this app?")}</DialogTitle>
						<DialogDescription>
							{t("The app that sent you here will be told you said no. Your Engram account stays.")}
						</DialogDescription>
					</DialogHeader>
					<DialogFooter>
						<Button type="button" variant="outline" onClick={() => setConfirmCancel(false)}>
							{t("Keep setting up")}
						</Button>
						<Button type="button" onClick={cancelPending}>
							{t("Stop connecting")}
						</Button>
					</DialogFooter>
				</DialogContent>
			</Dialog>
		</AuthShell>
	);
}
