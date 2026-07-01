import { useCallback, useState } from "react";
import { Navigate, useNavigate } from "react-router";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { api } from "../api/client";
import { useOnboardingStatus, type OnboardingStatus } from "../api/queries";
import BillingPage from "../billing/billing-page";
import { FREE_TIER } from "../billing/plan-cards";

function nextPath(status: OnboardingStatus): string {
	return status.next_step === "done" ? "/" : `/onboard/${status.next_step}`;
}

export default function OnboardBillingPage() {
	const navigate = useNavigate();
	const qc = useQueryClient();
	const { data: onboarding } = useOnboardingStatus();
	const [freeLoading, setFreeLoading] = useState(false);
	// True while the inline Paddle checkout view is open — hides our own header +
	// free link so they don't sit stuck above/below the payment form.
	const [checkoutActive, setCheckoutActive] = useState(false);

	const onActivated = useCallback(
		(status: OnboardingStatus) => {
			navigate(nextPath(status), { replace: true });
		},
		[navigate],
	);

	const handleContinueFree = useCallback(async () => {
		setFreeLoading(true);
		try {
			const status = await api.post<OnboardingStatus>("/onboarding/accept_free_tier");
			qc.setQueryData(["onboarding", "status"], status);
			const next = status.next_step === "done" ? "/" : `/onboard/${status.next_step}`;
			navigate(next, { replace: true });
		} catch {
			toast.error("Could not continue. Please try again.");
		} finally {
			setFreeLoading(false);
		}
	}, [navigate, qc]);

	// Cached/fetched status already past billing (e.g. user advanced in another
	// tab, or returned to /onboard/billing after subscribing) — bounce forward
	// to their actual next step instead of re-showing the plan picker. Keys off
	// `next_step`, not `steps` (billing stays in `steps` even once satisfied).
	if (onboarding && onboarding.next_step !== "billing") {
		return <Navigate to={nextPath(onboarding)} replace />;
	}

	return (
		<section className="m-auto max-h-full w-full max-w-2xl overflow-y-auto px-4 pb-8 pt-5 sm:pt-8">
			<div className="rounded-2xl border border-border bg-background p-4 sm:p-8">
				{/* Header is hidden once a plan is chosen (checkout view open) so it
            doesn't sit stuck above the Paddle payment form. */}
				{!checkoutActive && (
					<header className="mb-4 text-center sm:mb-8">
						<h1 className="text-2xl font-extrabold tracking-tight text-foreground sm:text-4xl">
							Choose your plan
						</h1>
						<p className="mx-auto mt-1.5 max-w-md text-balance text-sm text-muted-foreground sm:mt-3 sm:text-base">
							7-day free trial on paid plans. Card required, no charge until it ends.
						</p>
					</header>
				)}
				{/* Mobile: Free joins the secondary-tier accordion inside BillingPage
            (one shared open-at-a-time state) via freeOption. Desktop keeps the
            understated bottom link below. */}
				<BillingPage
					hideHeading
					onActivated={onActivated}
					freeOption={{ onContinue: handleContinueFree, loading: freeLoading }}
					onCheckoutActiveChange={setCheckoutActive}
				/>
				{/* Desktop: understated bottom link — also hidden during checkout so it
            doesn't sit stuck below the payment form. */}
				{!checkoutActive && (
					<section className="mt-12 hidden border-t border-border pt-8 text-center sm:block">
						<button
							type="button"
							onClick={handleContinueFree}
							disabled={freeLoading}
							className="text-sm font-medium text-muted-foreground underline underline-offset-4 hover:text-foreground disabled:opacity-50"
						>
							Continue with Free →
						</button>
						<p className="mt-2 text-xs text-muted-foreground">
							{FREE_TIER.summary} · upgrade anytime
						</p>
					</section>
				)}
			</div>
		</section>
	);
}
