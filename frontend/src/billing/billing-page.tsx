import { CheckoutEventNames, initializePaddle, type Paddle } from "@paddle/paddle-js";
import { useQueryClient } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { ctaFilled, ctaOutline } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";
import { api } from "../api/client";
import {
	type BillingCadence,
	invalidateBillingState,
	type OnboardingStatus,
	useBillingConfig,
	useBillingHistory,
	useBillingStatus,
	useBillingSubscriptionDetail,
	useMe,
} from "../api/queries";
import { useTheme } from "../theme/theme-provider";
import BillingHistoryTable from "./billing-history-table";
import CancelPanel from "./cancel-panel";
import CurrentPlanCard from "./current-plan-card";
import PaymentMethodCard from "./payment-method-card";
import PendingChangeBanner from "./pending-change-banner";
import {
	CadenceToggle,
	FREE_TIER,
	formatPlanPrice,
	PLAN_CATALOG,
	PlanAccordionRow,
	PlanCard,
} from "./plan-cards";
import PlanChangePanel from "./plan-change-panel";
import { useSubscriptionActivatedEvents } from "./use-subscription-activated-events";

// Time after CHECKOUT_COMPLETED we keep Paddle's own "Payment successful"
// screen visible while waiting for the backend subscription_activated push.
// Past this we close Paddle and surface a small recovery banner — the push
// listener stays connected, so a late broadcast still routes the user.
const COOLDOWN_MS = 15_000;

const INLINE_FRAME_TARGET = "paddle-checkout";

// Dev-only: Paddle's checkout iframe can't embed on a non-default-port
// localhost origin (its frame-ancestors only allows the bare host at :80/:443),
// so `vite dev` swaps the real frame for a stub that lets you walk the whole
// onboarding flow. `import.meta.env.DEV` is false in production builds, so this
// path is compiled out and never ships. Excluded under `TEST` so unit tests
// exercise the real inline-frame path (vitest sets DEV=true too).
const DEV_FAKE_CHECKOUT = import.meta.env.DEV && !import.meta.env.TEST;

async function downloadInvoice(transactionId: string) {
	try {
		const { url } = await api.get<{ url: string }>(
			`/billing/transactions/${transactionId}/invoice`,
		);
		window.open(url, "_blank", "noopener");
	} catch {
		toast.error("Could not fetch that invoice. Please try again.");
	}
}

interface BillingPageProps {
	hideHeading?: boolean;
	onActivated?: (status: OnboardingStatus) => void;
	// Onboarding-only: renders a "Free" row in the mobile accordion group so all
	// tiers share one open-at-a-time state. Settings omits it (no free option
	// there). Routes through a different handler than the paid checkout.
	freeOption?: { onContinue: () => void; loading?: boolean };
	// Onboarding-only: fired when the inline Paddle checkout view opens/closes so
	// the wrapper can hide its own chrome (header, free link) during payment.
	onCheckoutActiveChange?: (active: boolean) => void;
}

function SlowActivationBanner({
	transactionId,
	onRefresh,
}: {
	transactionId: string | null;
	onRefresh: () => void;
}) {
	return (
		<div role="alert" className="rounded-lg border border-border bg-muted/50 p-4 text-sm">
			<p className="font-medium text-foreground">
				Payment received. We're finishing your activation in the background.
			</p>
			<p className="mt-1 text-muted-foreground">
				This usually takes seconds. Refresh in a moment, or contact support if it persists.
			</p>
			<div className="mt-3 flex flex-wrap gap-2">
				<Button size="sm" onClick={onRefresh}>
					Refresh
				</Button>
				<Button
					size="sm"
					variant="outline"
					onClick={() => {
						const subject = encodeURIComponent("Activation taking too long");
						const body = encodeURIComponent(
							`Hi — my payment went through but my account hasn't activated.\n\nReference: ${transactionId ?? "n/a"}`,
						);
						window.location.href = `mailto:support@engram.page?subject=${subject}&body=${body}`;
					}}
				>
					Contact support
				</Button>
			</div>
			{transactionId ? (
				<p className="mt-3 text-muted-foreground text-xs">Reference: {transactionId}</p>
			) : null}
		</div>
	);
}

// Skeleton placeholder that matches the post-load layout so the page does
// not jump when billing status + Paddle init resolve. Shape: optional
// heading, cadence toggle row, two cards in the same grid as the real cards.
function BillingPageSkeleton({ hideHeading }: { hideHeading: boolean }) {
	return (
		<article className="space-y-6" aria-busy="true" aria-label="Loading billing">
			{!hideHeading && (
				<header className="space-y-2">
					<Skeleton className="h-6 w-32" />
					<Skeleton className="h-4 w-64" />
				</header>
			)}
			<section className="space-y-4">
				<Skeleton className="h-9 w-48" />
				<ul className="grid items-stretch gap-4 sm:grid-cols-2">
					{[0, 1].map((i) => (
						<li key={i} className="flex flex-col gap-4 rounded-lg border border-border bg-card p-6">
							<Skeleton className="h-6 w-24" />
							<Skeleton className="h-9 w-32" />
							<Skeleton className="h-3 w-40" />
							<ul className="space-y-2 pt-2">
								{[0, 1, 2, 3].map((j) => (
									<li key={j}>
										<Skeleton className="h-4 w-full" />
									</li>
								))}
							</ul>
							<Skeleton className="mt-2 h-10 w-full" />
						</li>
					))}
				</ul>
			</section>
		</article>
	);
}

export default function BillingPage({
	hideHeading = false,
	onActivated,
	freeOption,
	onCheckoutActiveChange,
}: BillingPageProps) {
	// Onboarding mounts BillingPage with onActivated; settings does not. The
	// prop's presence is what flips Paddle from overlay → inline. Inline gives
	// the wizard step a continuous look (plan cards swap to Paddle's frame in
	// the same panel); overlay is the right shape for an on-demand settings
	// action where users expect a modal.
	const isInline = typeof onActivated === "function";

	const { data: billing, isLoading } = useBillingStatus();
	const { data: config } = useBillingConfig();
	const { data: me } = useMe();
	const hasSubscription = Boolean(billing?.subscription);
	const { data: detail } = useBillingSubscriptionDetail(hasSubscription);
	const { data: history } = useBillingHistory(hasSubscription);
	const { resolved } = useTheme();
	const qc = useQueryClient();
	const [paddle, setPaddle] = useState<Paddle>();
	// Ref mirror of `paddle` so the eventCallback (captured pre-instance) can
	// call Checkout.close() on push activation or cooldown without re-init.
	const paddleRef = useRef<Paddle | undefined>(undefined);
	const [cadence, setCadence] = useState<BillingCadence>("monthly");
	// Mobile tier accordion: which row is expanded. Exactly one is always open
	// (re-clicking the open tier keeps it open); Pro is the default.
	const [openTier, setOpenTier] = useState<"pro" | "starter" | "free">("pro");

	// View states for the plan-picker section.
	//   idle      → plan cards visible
	//   checkout  → inline mode: Paddle frame mounted; overlay mode: modal open
	//   slow      → cooldown elapsed without a push event; show recovery banner
	const [checkingOut, setCheckingOut] = useState(false);
	const [completedAt, setCompletedAt] = useState<number | null>(null);
	const [slow, setSlow] = useState(false);
	// Onboarding-only bridge: held from activation until the redirect fires, so we
	// show a single steady "finishing up" view instead of flashing the empty plan
	// picker while queries invalidate + status refetches.
	const [finalizing, setFinalizing] = useState(false);
	const [transactionId, setTransactionId] = useState<string | null>(null);
	// Inline panel state for the in-app cancel + plan-change flows (replaces
	// the previous openPortal('cancel') / portal-redirect path).
	const [panel, setPanel] = useState<"cancel" | "change" | null>(null);
	// Shared latch for any click that does an api.get → Paddle round-trip
	// before navigating away or opening the overlay. The portal-redirect and
	// payment-update flows both incur the same backend round-trip, so the
	// user needs immediate feedback that the click registered.
	const [portalLoading, setPortalLoading] = useState(false);

	// Latch — onActivated must fire at most once even if the broadcast lands
	// multiple times (subscription.created followed by subscription.activated
	// on a trial→active flip).
	const onActivatedFiredRef = useRef(false);
	const onActivatedRef = useRef(onActivated);
	onActivatedRef.current = onActivated;

	// Cooldown timer — starts on CHECKOUT_COMPLETED. If the activation push
	// doesn't land within COOLDOWN_MS, swap from Paddle's own success screen
	// to our recovery banner. The push listener stays connected.
	useEffect(() => {
		if (completedAt === null) {
			return;
		}
		const t = setTimeout(() => {
			paddleRef.current?.Checkout.close();
			setSlow(true);
			setCheckingOut(false);
		}, COOLDOWN_MS);
		return () => clearTimeout(t);
	}, [completedAt]);

	// Push handler — Paddle webhook flipped the subscription server-side and
	// the user channel just told us. Close Paddle, refresh local query state,
	// and (in onboarding mode) fetch the fresh onboarding/status to decide
	// where to route the user next.
	const handleSubscriptionActivated = useCallback(async () => {
		// Onboarding: hold a steady "finishing up" view across the async work below
		// so we never flash the empty plan picker before the redirect. Gate on the
		// fire latch too: a duplicate/late activation broadcast after the first
		// fire must NOT re-raise `finalizing` (the reset/navigate path below is
		// skipped once fired, which would otherwise strand the spinner forever).
		if (onActivatedRef.current && !onActivatedFiredRef.current) {
			setFinalizing(true);
		}
		paddleRef.current?.Checkout.close();
		setCheckingOut(false);
		setCompletedAt(null);
		setSlow(false);
		await invalidateBillingState(qc);
		await qc.invalidateQueries({ queryKey: ["onboarding", "status"] });

		if (onActivatedRef.current && !onActivatedFiredRef.current) {
			try {
				const status = await qc.fetchQuery<OnboardingStatus>({
					queryKey: ["onboarding", "status"],
					queryFn: () => api.get<OnboardingStatus>("/onboarding/status"),
					staleTime: 0,
				});
				if (!onActivatedFiredRef.current) {
					onActivatedFiredRef.current = true;
					onActivatedRef.current(status);
				}
			} catch (err) {
				console.error("failed to refetch onboarding/status after activation", err);
				setFinalizing(false);
			}
		}
	}, [qc]);

	useSubscriptionActivatedEvents({
		userId: me?.id ?? null,
		enabled: true,
		onActivated: handleSubscriptionActivated,
	});

	// Mount-time cache check: if the user lands on billing with a cached
	// onboarding status already past 'billing' AND has a paid subscription,
	// fire onActivated synchronously instead of waiting on a push event
	// (paid in another tab, browser-back, refresh). Only meaningful in
	// onboarding mode. Skipped for Free users who deliberately re-visit
	// /onboard/billing to upgrade — bouncing them back to the next step
	// defeats the upgrade affordance.
	useEffect(() => {
		if (!onActivatedRef.current) {
			return;
		}
		if (!billing?.active) {
			return;
		}
		const cached = qc.getQueryData<OnboardingStatus>(["onboarding", "status"]);
		if (cached && cached.next_step !== "billing" && !onActivatedFiredRef.current) {
			onActivatedFiredRef.current = true;
			onActivatedRef.current(cached);
		}
		// mount-only — qc identity is stable, onActivated read via ref.
		// billing?.active read on first paint; the page renders Loading first
		// anyway and we only want the synchronous case (cache hit).
		// eslint-disable-next-line react-hooks/exhaustive-deps
	}, []);

	useEffect(() => {
		if (!config) {
			return;
		}
		let cancelled = false;
		initializePaddle({
			token: config.client_token,
			environment: config.environment,
			eventCallback: (event) => {
				if (cancelled) {
					return;
				}
				switch (event.name) {
					case CheckoutEventNames.CHECKOUT_PAYMENT_INITIATED: {
						// Belt-and-suspenders: either PAYMENT_INITIATED or COMPLETED may
						// drop on trial-signup redirects. Arm the cooldown timer on
						// whichever fires first (`?? Date.now()` guards against reset)
						// so a dropped COMPLETED still surfaces the recovery banner
						// instead of stranding the user on Paddle's inline frame.
						const txn =
							(event.data as { transaction_id?: string } | undefined)?.transaction_id ?? null;
						setTransactionId(txn);
						setCompletedAt((prev) => prev ?? Date.now());
						invalidateBillingState(qc);
						break;
					}
					case CheckoutEventNames.CHECKOUT_COMPLETED: {
						// Don't close Paddle — its built-in "Payment successful" screen
						// is the visible confirmation while we wait for the backend
						// webhook to fire the subscription_activated push. The cooldown
						// timer is the fallback if the push never arrives (and is also
						// armed here in case PAYMENT_INITIATED dropped).
						setCompletedAt((prev) => prev ?? Date.now());
						invalidateBillingState(qc);
						break;
					}
					case CheckoutEventNames.CHECKOUT_PAYMENT_FAILED: {
						// A declined card is a normal, retryable state: Paddle keeps its
						// inline frame open and shows the reason ("card declined",
						// "insufficient funds", …) with a retry. Leave the frame mounted
						// (do NOT setCheckingOut(false)) so the user sees WHY and can try
						// another card, instead of being bounced back to the plan picker
						// with no explanation. Only clear the completion cooldown/recovery
						// state so a stale COMPLETED/INITIATED timer can't fire.
						setCompletedAt(null);
						setSlow(false);
						break;
					}
					case CheckoutEventNames.CHECKOUT_PAYMENT_ERROR:
					case CheckoutEventNames.CHECKOUT_ERROR: {
						// Genuine checkout-level error (not a routine decline) — the frame
						// may be in a broken state, so close it and surface a message.
						setCheckingOut(false);
						setCompletedAt(null);
						setSlow(false);
						toast.error("Something went wrong with checkout. Please try again.");
						break;
					}
					default:
						break;
				}
			},
			checkout: {
				settings: isInline
					? {
							displayMode: "inline",
							frameTarget: INLINE_FRAME_TARGET,
							frameInitialHeight: 450,
							// No fixed min-height: Paddle auto-resizes the iframe to fit its
							// content, and a hard floor overrode the downward resize — so the
							// short post-payment success screen was stranded in a tall 450px
							// box. frameInitialHeight covers the initial paint before Paddle
							// reports the real height. (min-width matches Paddle's own sample.)
							frameStyle: "width:100%; min-width:312px; background:transparent; border:none;",
							theme: resolved === "dark" ? "dark" : "light",
							locale: "en",
						}
					: {
							displayMode: "overlay",
							theme: resolved === "dark" ? "dark" : "light",
							locale: "en",
						},
			},
		}).then((instance) => {
			if (cancelled) {
				return;
			}
			if (instance) {
				paddleRef.current = instance;
				setPaddle(instance);
			}
		});
		return () => {
			cancelled = true;
			paddleRef.current = undefined;
			setPaddle(undefined);
		};
	}, [config, resolved, qc, isInline]);

	// Open checkout. In inline mode we set checkingOut first so the mount
	// div is in the DOM before Paddle tries to find it.
	const handleStartCheckout = useCallback(
		(tier: "starter" | "pro") => {
			// Dev stub: skip the (un-embeddable) Paddle frame, show the stand-in.
			if (DEV_FAKE_CHECKOUT) {
				setCheckingOut(true);
				return;
			}
			if (!(paddle && config)) {
				return;
			}
			if (isInline) {
				setCheckingOut(true);
			}
			// Paddle finds the .paddle-checkout div by class — the div is rendered
			// synchronously by the same render cycle as the setCheckingOut update.
			// React 18 batches state into the same commit, so the DOM is ready by
			// the time Paddle queries it on the next microtask.
			queueMicrotask(() => {
				paddle.Checkout.open({
					items: [{ priceId: config.price_ids[tier][cadence], quantity: 1 }],
					customer: { email: config.customer_email },
					customData: config.custom_data,
				});
			});
		},
		[paddle, config, cadence, isInline],
	);

	// Dev stub success: satisfy the backend onboarding gate via the free-tier
	// path (the only billing decision we can make without Paddle) so the wizard
	// advances to the next step. Dev-only; never invoked in production.
	const handleDevCheckoutSuccess = useCallback(async () => {
		setFinalizing(true);
		try {
			const status = await api.post<OnboardingStatus>("/onboarding/accept_free_tier");
			qc.setQueryData(["onboarding", "status"], status);
			setCheckingOut(false);
			// Honor the at-most-once latch like the real activation path, so a
			// trailing push/mount-fire can't double-invoke onActivated.
			if (!onActivatedFiredRef.current) {
				onActivatedFiredRef.current = true;
				onActivatedRef.current?.(status);
			}
		} catch {
			setFinalizing(false);
			toast.error("Could not simulate checkout. Please try again.");
		}
	}, [qc]);

	// Tell the onboarding wrapper when the inline checkout view is showing (paddle
	// frame or the slow-activation banner) so it can hide its own header + free
	// link during payment. Ref-mirrored so the effect only depends on the boolean.
	const checkoutActive = isInline && (checkingOut || slow || finalizing);
	const onCheckoutActiveChangeRef = useRef(onCheckoutActiveChange);
	onCheckoutActiveChangeRef.current = onCheckoutActiveChange;
	useEffect(() => {
		onCheckoutActiveChangeRef.current?.(checkoutActive);
	}, [checkoutActive]);

	if (isLoading || !billing) {
		return <BillingPageSkeleton hideHeading={hideHeading} />;
	}

	const needsSubscription = !billing.active;
	// Keep the panel mounted across the activation flip: the push that raises the
	// `finalizing` bridge also flips billing.active → needsSubscription false.
	const showPlanSection = needsSubscription || finalizing;
	const checkoutReady = Boolean(paddle && config);

	async function openPortal(action?: string) {
		setPortalLoading(true);
		try {
			const path = action ? `/billing/portal?action=${action}` : "/billing/portal";
			const { url } = await api.get<{ url: string }>(path);
			window.location.href = url;
		} catch {
			toast.error("Could not open the billing portal. Please try again.");
			setPortalLoading(false);
		}
	}

	async function handleUpdatePayment() {
		if (!paddle) {
			openPortal("update_payment");
			return;
		}

		setPortalLoading(true);
		try {
			const { transaction_id } = await api.get<{ transaction_id: string }>(
				"/billing/payment-update-transaction",
			);
			paddle.Checkout.open({ transactionId: transaction_id });
		} catch {
			toast.error("Could not start the payment update. Please try again.");
		} finally {
			setPortalLoading(false);
		}
	}

	return (
		<article className="space-y-6">
			{!hideHeading && (
				<header>
					<h1 className="font-semibold text-foreground text-xl">Billing</h1>
					<p className="mt-1 text-muted-foreground text-sm">Manage your plan and payment method.</p>
				</header>
			)}

			{!hideHeading && (
				<CurrentPlanCard billing={billing}>
					{billing.subscription && panel === null && (
						<div className="flex flex-wrap justify-end gap-3">
							<Button onClick={() => setPanel("change")}>Change plan</Button>
							{/* Hide Cancel when (a) the subscription is already canceled,
                  OR (b) a scheduled cancel is in flight — Paddle keeps
                  status='active' until the effective date, so without the
                  scheduled_change check the button stays clickable and the
                  second click 5xx's ('subscription already scheduled to
                  cancel') with a vague 'Could not cancel' toast. */}
							{billing.subscription.status !== "canceled" &&
								detail?.scheduled_change?.action !== "cancel" && (
									<Button variant="destructive" onClick={() => setPanel("cancel")}>
										Cancel subscription
									</Button>
								)}
						</div>
					)}
					{billing.subscription && panel === "change" && (
						<PlanChangePanel
							billing={billing}
							onClose={() => setPanel(null)}
							onSwitchToCancel={() => setPanel("cancel")}
						/>
					)}
					{billing.subscription && panel === "cancel" && (
						<CancelPanel
							detail={
								detail ?? {
									next_billed_at: billing.subscription.current_period_end,
									amount: null,
									currency: null,
									billing_cycle: null,
									scheduled_change: null,
								}
							}
							tier={billing.tier}
							onClose={() => setPanel(null)}
						/>
					)}
				</CurrentPlanCard>
			)}

			{/* showPlanSection = needsSubscription || finalizing — keeps the bridge
			    mounted across the activation flip so it doesn't flash blank before
			    the wizard navigates to the next step. */}
			{showPlanSection ? (
				<section className="space-y-4">
					{finalizing ? (
						<section
							aria-live="polite"
							className="flex flex-col items-center justify-center gap-3 py-16 text-center"
						>
							<Loader2 className="size-6 animate-spin text-primary" aria-hidden="true" />
							<p className="text-muted-foreground text-sm">Setting up your account…</p>
						</section>
					) : slow ? (
						<SlowActivationBanner
							transactionId={transactionId}
							onRefresh={() => window.location.reload()}
						/>
					) : isInline && checkingOut ? (
						<>
							<button
								type="button"
								onClick={() => {
									paddleRef.current?.Checkout.close();
									setCheckingOut(false);
									setCompletedAt(null);
								}}
								className="text-muted-foreground text-sm underline-offset-4 hover:text-foreground hover:underline"
							>
								← Choose a different plan
							</button>
							{DEV_FAKE_CHECKOUT ? (
								<div className="rounded-lg border border-primary/50 border-dashed bg-muted/30 p-6 text-center">
									<p className="font-medium text-foreground text-sm">Test checkout (dev only)</p>
									<p className="mx-auto mt-1 max-w-sm text-muted-foreground text-xs">
										Paddle's checkout can't embed on localhost, so this stand-in lets you walk the
										flow. Not shown in production.
									</p>
									<div className="mt-4 flex flex-col gap-2 sm:flex-row sm:justify-center">
										<button
											type="button"
											onClick={handleDevCheckoutSuccess}
											className={cn(
												"rounded-lg px-4 py-2 font-medium text-sm transition",
												ctaFilled,
											)}
										>
											Simulate successful payment
										</button>
										<button
											type="button"
											onClick={() => {
												setCheckingOut(false);
												toast.error("Payment did not go through. Please try again.");
											}}
											className={cn(
												"rounded-lg px-4 py-2 font-medium text-sm transition",
												ctaOutline,
											)}
										>
											Simulate failure
										</button>
									</div>
								</div>
							) : (
								<div className={INLINE_FRAME_TARGET} />
							)}
						</>
					) : (
						<>
							{!hideHeading && (
								<>
									<h2 className="font-semibold text-foreground text-lg">Choose a Plan</h2>
									<p className="text-muted-foreground text-sm">
										Both plans include a 7-day free trial.
									</p>
								</>
							)}
							<CadenceToggle cadence={cadence} onChange={setCadence} />
							{/* Desktop: side-by-side full cards. */}
							<ul className="hidden items-stretch gap-4 sm:grid sm:grid-cols-2">
								<PlanCard
									name={PLAN_CATALOG.starter.name}
									cadence={cadence}
									monthlyPrice={PLAN_CATALOG.starter.monthlyPrice}
									annualPrice={PLAN_CATALOG.starter.annualPrice}
									features={PLAN_CATALOG.starter.features}
									tier="starter"
									onAction={handleStartCheckout}
									disabled={!checkoutReady}
								/>
								<PlanCard
									name={PLAN_CATALOG.pro.name}
									cadence={cadence}
									monthlyPrice={PLAN_CATALOG.pro.monthlyPrice}
									annualPrice={PLAN_CATALOG.pro.annualPrice}
									features={PLAN_CATALOG.pro.features}
									tier="pro"
									onAction={handleStartCheckout}
									disabled={!checkoutReady}
									recommended
								/>
							</ul>
							{/* Mobile: all tiers as a single one-open-at-a-time accordion.
                  Pro is open by default + visually emphasized; opening any tier
                  collapses the others. */}
							<ul className="flex flex-col gap-2 sm:hidden">
								<PlanAccordionRow
									name={PLAN_CATALOG.pro.name}
									price={formatPlanPrice(PLAN_CATALOG.pro, cadence)}
									summary="15 vaults · 15 GB · unlimited AI"
									features={PLAN_CATALOG.pro.features}
									ctaLabel="Choose Pro"
									ctaNote="7-day free trial · cancel anytime"
									onClick={() => handleStartCheckout("pro")}
									disabled={!checkoutReady}
									recommended
									open={openTier === "pro"}
									onOpen={() => setOpenTier("pro")}
								/>
								<PlanAccordionRow
									name={PLAN_CATALOG.starter.name}
									price={formatPlanPrice(PLAN_CATALOG.starter, cadence)}
									summary="5 vaults · 3 GB · 500 AI queries/day"
									features={PLAN_CATALOG.starter.features}
									ctaLabel="Choose Starter"
									ctaNote="7-day free trial · cancel anytime"
									onClick={() => handleStartCheckout("starter")}
									disabled={!checkoutReady}
									open={openTier === "starter"}
									onOpen={() => setOpenTier("starter")}
								/>
								{freeOption ? (
									<PlanAccordionRow
										name={FREE_TIER.name}
										price={FREE_TIER.price}
										summary={FREE_TIER.summary}
										features={[...FREE_TIER.features]}
										ctaLabel="Choose Free"
										onClick={freeOption.onContinue}
										disabled={freeOption.loading}
										quietCta
										open={openTier === "free"}
										onOpen={() => setOpenTier("free")}
									/>
								) : null}
							</ul>
						</>
					)}
				</section>
			) : null}

			{!hideHeading && billing.subscription && (
				<>
					<PendingChangeBanner scheduledChange={detail?.scheduled_change ?? null} />
					<PaymentMethodCard
						paymentMethod={history?.payment_method ?? null}
						onUpdate={handleUpdatePayment}
						updating={portalLoading}
					/>
					<BillingHistoryTable
						transactions={history?.transactions ?? []}
						onDownload={downloadInvoice}
					/>
					{/* Escape hatch: if the inline panels above fail (Paddle UI bug,
              network blip, an action we don't yet support inline) the user
              can still self-serve through Paddle's hosted portal. Sits
              outside the cards so it reads as a fallback option, not as
              one of the primary plan actions. */}
					<div className="flex flex-col items-center gap-1.5 pt-2">
						<Button
							type="button"
							variant="outline"
							onClick={() => openPortal()}
							disabled={portalLoading}
						>
							{Boolean(portalLoading) && <Loader2 aria-hidden className="size-4 animate-spin" />}
							{portalLoading ? "Opening Paddle…" : "Open Paddle billing portal"}
						</Button>
						<p className="text-muted-foreground text-xs">
							Paddle is our payment processor. Use this if the controls above don't cover what you
							need.
						</p>
					</div>
				</>
			)}
		</article>
	);
}
