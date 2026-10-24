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

// Whether each Paddle.js payment method is offered on a checkout whose first
// charge is $0 (a trial that requires a payment method). A Record over the
// `AvailablePaymentMethod` union, so a paddle-js bump that adds a method fails
// the type check here rather than silently hiding it. Paddle still shows only
// the methods enabled and available on the account.
// Google Pay is off: prod 2026-10-24, three Google Pay attempts on a trial
// checkout each stuck at `action_required` with no error, most likely its
// zero-amount authorization never completing. Reversible: flip it to true.
const ON_ZERO_FIRST_CHARGE: Record<AvailablePaymentMethod, boolean> = {
	alipay: true,
	apple_pay: true,
	bancontact: true,
	blik: true,
	card: true,
	google_pay: false,
	ideal: true,
	kakao_pay: true,
	south_korea_local_card: true,
	mb_way: true,
	naver_pay: true,
	payco: true,
	paypal: true,
	pix: true,
	samsung_pay: true,
	saved_payment_methods: true,
	upi: true,
	wechat_pay: true,
};

function isPaymentMethod(key: string): key is AvailablePaymentMethod {
	return Object.hasOwn(ON_ZERO_FIRST_CHARGE, key);
}

const ZERO_FIRST_CHARGE_METHODS = Object.keys(ON_ZERO_FIRST_CHARGE)
	.filter(isPaymentMethod)
	.filter((m) => ON_ZERO_FIRST_CHARGE[m]);

/** What Paddle.js needs to boot: the public client-side token + environment. */
export interface PaddleClientConfig {
	client_token: string;
	environment: "sandbox" | "production";
}

export const INLINE_FRAME_TARGET = "paddle-checkout";

export interface CheckoutOptions {
	/** First charge is $0. True for plan purchases: every plan price carries a
	 *  trial (the plan cards promise "7-day free trial"). */
	zeroFirstCharge?: boolean;
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
// `zeroFirstCharge` is per-open only, never in the init defaults, so the /pay
// page (renewals, invoices: real amounts) keeps every method.
export function checkoutSettings(
	isInline: boolean,
	{ zeroFirstCharge = false }: CheckoutOptions = {},
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
	return zeroFirstCharge
		? { ...display, allowedPaymentMethods: ZERO_FIRST_CHARGE_METHODS }
		: display;
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
