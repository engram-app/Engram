// Paddle.js setup shared by every page that opens a checkout: the billing
// page (plan purchase, payment-method update) and /pay (Paddle's default
// payment link). One init and one settings shape, so a checkout opened from a
// Paddle email link behaves like one opened in the app.
import {
	type AvailablePaymentMethod,
	type CheckoutSettings,
	initializePaddle,
	type Paddle,
	type PaddleEventData,
} from "@paddle/paddle-js";

// Payment methods offered on a $0 checkout (a trial that requires a payment
// method, or an active subscription's payment-method update). Mapped over the
// `AvailablePaymentMethod` union, so a paddle-js bump that adds a method fails
// the type check here rather than silently hiding it, and each value must be
// its own key. Paddle still shows only the methods enabled and available on
// the account.
// Google Pay is off: prod 2026-10-24, three Google Pay attempts on a trial
// checkout each stuck at `action_required` with no error. Suspected (not
// confirmed with Paddle): its zero-amount authorization never completes.
// Reversible: set it back to "google_pay".
const ON_ZERO_AMOUNT: { [M in AvailablePaymentMethod]: M | false } = {
	alipay: "alipay",
	apple_pay: "apple_pay",
	bancontact: "bancontact",
	blik: "blik",
	card: "card",
	google_pay: false,
	ideal: "ideal",
	kakao_pay: "kakao_pay",
	south_korea_local_card: "south_korea_local_card",
	mb_way: "mb_way",
	naver_pay: "naver_pay",
	payco: "payco",
	paypal: "paypal",
	pix: "pix",
	samsung_pay: "samsung_pay",
	saved_payment_methods: "saved_payment_methods",
	upi: "upi",
	wechat_pay: "wechat_pay",
};

const ZERO_AMOUNT_METHODS = Object.values(ON_ZERO_AMOUNT).filter((m) => m !== false);

/** What Paddle.js needs to boot: the public client-side token + environment. */
export interface PaddleClientConfig {
	client_token: string;
	environment: "sandbox" | "production";
}

export const INLINE_FRAME_TARGET = "paddle-checkout";

export interface CheckoutOptions {
	/** The checkout authorizes $0: plan purchases (every plan price carries a
	 *  7-day trial, as the plan cards promise) and payment-method updates
	 *  (Paddle's update transaction is $0 for an active subscription). */
	zeroAmount?: boolean;
}

// Paddle's branded-inline-checkout dashboard config (Paddle > Checkout
// > Branded inline checkout) is a single static color set with no
// light/dark variant, tuned for light. `theme: "light"` matches it so
// the unbranded chrome (page background behind fields, default text)
// doesn't clash with the branded fields. Fixed, not tied to the app's
// live theme — a dynamic value here tore down/rebuilt the Paddle
// instance on every app theme toggle, stranding an open checkout.
// Stable inputs only (isInline): the init effect depends on this shape, and
// the locale is layered on at call time. Each Checkout.open gets the FULL
// object, because Paddle.js's merge of partial per-open settings over the
// init defaults is undocumented and this is the payments path.
// `zeroAmount` is per-open only, never in the init defaults, so the /pay
// page (renewals, invoices: real amounts) keeps every method.
export function checkoutSettings(
	isInline: boolean,
	{ zeroAmount = false }: CheckoutOptions = {},
): CheckoutSettings {
	const display: CheckoutSettings = isInline
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
				theme: "light",
				variant: "one-page",
			}
		: { displayMode: "overlay", theme: "light", variant: "one-page" };
	return zeroAmount ? { ...display, allowedPaymentMethods: ZERO_AMOUNT_METHODS } : display;
}

// `locale: "en"` is only the default; every Checkout.open passes the full
// settings again with the rendered app locale (see checkoutSettings).
export function initPaddle(
	config: PaddleClientConfig,
	isInline: boolean,
	eventCallback?: (event: PaddleEventData) => void,
): Promise<Paddle | undefined> {
	return initializePaddle({
		token: config.client_token,
		environment: config.environment,
		eventCallback,
		checkout: { settings: { ...checkoutSettings(isInline), locale: "en" } },
	});
}
