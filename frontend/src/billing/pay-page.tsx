import { CheckoutEventNames, type Paddle, type PaddleEventData } from "@paddle/paddle-js";
import { Loader2 } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";
import { Link, useSearchParams } from "react-router";
import { Button } from "@/components/ui/button";
import { heading } from "@/lib/ui-classes";
import { usePaddleClientConfig } from "../api/queries";
import { useT } from "../i18n/locale-provider";
import { Trans } from "../i18n/trans";
import { paddleLocale } from "../i18n/vendor-locales";
import AuthPanel from "../layout/auth-panel";
import AuthShell from "../layout/auth-shell";
import { SUPPORT_EMAIL, SUPPORT_MAILTO } from "../lib/support";
import { ROUTES } from "../routes";
import { checkoutSettings, initPaddle } from "./paddle-checkout";

// Paddle's own id shape (`txn_` + 26 lowercase base32 chars, per its API spec).
const TRANSACTION_ID = /^txn_[a-z\d]{26}$/;

type View = "loading" | "invalid" | "paid" | "canceled" | "closed" | "completed" | "error";

/** The page's view for a Paddle.js event, or null to keep the current one. */
export function viewForEvent(event: PaddleEventData, settled: boolean): View | null {
	switch (event.name) {
		case CheckoutEventNames.CHECKOUT_COMPLETED:
			return "completed";
		// After completed / paid / canceled the close is the overlay going away
		// (ours or the buyer's), not an abandon: keep the settled view.
		case CheckoutEventNames.CHECKOUT_CLOSED:
			return settled ? null : "closed";
		case CheckoutEventNames.CHECKOUT_LOADED: {
			// A link mailed for a transaction that has since been paid or canceled.
			const status = event.data?.status;
			if (status === "completed" || status === "paid") {
				return "paid";
			}
			return status === "canceled" ? "canceled" : null;
		}
		case CheckoutEventNames.CHECKOUT_ERROR:
			return "invalid";
		default:
			return null;
	}
}

/** Paddle's default payment link. Paddle mails `<this page>?_ptxn=<txn id>`
 *  for renewals, payment-method updates and invoices, so it must work in a
 *  fresh logged-out tab: it boots Paddle.js from the public client config and
 *  opens the overlay checkout for that transaction. */
export default function PayPage() {
	const [params] = useSearchParams();
	const transactionId = params.get("_ptxn");
	const valid = transactionId !== null && TRANSACTION_ID.test(transactionId);
	const { data: config, isError } = usePaddleClientConfig();
	const { t, renderedLocale } = useT();
	const [view, setView] = useState<View>(valid ? "loading" : "invalid");
	const paddleRef = useRef<Paddle | undefined>(undefined);
	// Completed, already paid or canceled: nothing left to reopen.
	const settledRef = useRef(false);
	// Read through a ref: the locale resolves after first paint, and re-running
	// the init effect on that change would boot Paddle twice and open two overlays.
	const localeRef = useRef(renderedLocale);
	useEffect(() => {
		localeRef.current = renderedLocale;
	}, [renderedLocale]);

	const open = useCallback(() => {
		if (!(paddleRef.current && transactionId)) {
			return;
		}
		setView("loading");
		paddleRef.current.Checkout.open({
			transactionId,
			settings: { ...checkoutSettings(false), locale: paddleLocale(localeRef.current) },
		});
	}, [transactionId]);

	useEffect(() => {
		if (!(valid && config)) {
			return;
		}
		let cancelled = false;
		initPaddle(config, false, (event) => {
			if (cancelled) {
				return;
			}
			const next = viewForEvent(event, settledRef.current);
			if (next === "completed" || next === "paid" || next === "canceled") {
				settledRef.current = true;
			}
			if (next === "paid" || next === "canceled") {
				paddleRef.current?.Checkout.close();
			}
			if (next) {
				setView(next);
			}
		})
			.then((paddle) => {
				if (cancelled) {
					return;
				}
				if (!paddle) {
					setView("error");
					return;
				}
				paddleRef.current = paddle;
				open();
			})
			.catch(() => setView("error"));
		return () => {
			cancelled = true;
		};
	}, [valid, config, open]);

	const shownView: View = valid && isError ? "error" : view;
	const home = (
		<Button asChild variant="outline">
			<Link to={ROUTES.HOME}>{t("Go to Engram")}</Link>
		</Button>
	);

	return (
		<AuthShell>
			<AuthPanel className="flex flex-col items-center gap-4 text-center">
				{shownView === "loading" && (
					<p className="flex items-center gap-2 text-muted-foreground" aria-live="polite">
						<Loader2 className="size-4 animate-spin" aria-hidden />
						{t("Opening secure checkout…")}
					</p>
				)}
				{shownView === "invalid" && (
					<>
						<h1 className={heading}>{t("This payment link is invalid or has expired")}</h1>
						<p className="text-muted-foreground text-sm">
							<Trans
								text="Need help? Contact {support}."
								slots={{
									support: (
										<a className="underline" href={SUPPORT_MAILTO}>
											{SUPPORT_EMAIL}
										</a>
									),
								}}
							/>
						</p>
						{home}
					</>
				)}
				{shownView === "paid" && (
					<>
						<h1 className={heading}>{t("This payment has already been made")}</h1>
						{home}
					</>
				)}
				{shownView === "canceled" && (
					<>
						<h1 className={heading}>{t("This payment was canceled")}</h1>
						{home}
					</>
				)}
				{shownView === "closed" && (
					<>
						<h1 className={heading}>{t("Checkout closed")}</h1>
						<Button type="button" onClick={open}>
							{t("Reopen checkout")}
						</Button>
					</>
				)}
				{shownView === "completed" && (
					<>
						<h1 className={heading}>{t("Payment received")}</h1>
						<Button asChild>
							<Link to={ROUTES.HOME}>{t("Open Engram")}</Link>
						</Button>
					</>
				)}
				{shownView === "error" && (
					<>
						<p role="alert">{t("Something went wrong with checkout. Please try again.")}</p>
						{home}
					</>
				)}
			</AuthPanel>
		</AuthShell>
	);
}
