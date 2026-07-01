export type PaddlePaymentMethodType =
	| "alipay"
	| "apple_pay"
	| "bancontact"
	| "blik"
	| "card"
	| "google_pay"
	| "ideal"
	| "kakao_pay"
	| "south_korea_local_card"
	| "mb_way"
	| "naver_pay"
	| "offline"
	| "payco"
	| "paypal"
	| "pix"
	| "samsung_pay"
	| "unknown"
	| "upi"
	| "wechat_pay"
	| "wire_transfer"
	/** @deprecated Returned on historical transactions but replaced by `south_korea_local_card` in newer transactions */
	| "korea_local"
	| (string & {});

/** All Paddle card brand types from `transaction.payments[0].method_details.card.type` */
export type PaddleCardType =
	| "american_express"
	| "diners_club"
	| "discover"
	| "jcb"
	| "mada"
	| "maestro"
	| "mastercard"
	| "union_pay"
	| "unknown"
	| "visa"
	| (string & {});

const PAYMENT_METHOD_LABELS: Record<string, string> = {
	alipay: "Alipay",
	apple_pay: "Apple Pay",
	bancontact: "Bancontact",
	blik: "BLIK",
	card: "Card",
	google_pay: "Google Pay",
	ideal: "iDEAL",
	kakao_pay: "Kakao Pay",
	south_korea_local_card: "Korea local card",
	mb_way: "MB WAY",
	naver_pay: "Naver Pay",
	offline: "Offline",
	payco: "PAYCO",
	paypal: "PayPal",
	pix: "Pix",
	samsung_pay: "Samsung Pay",
	unknown: "Payment method",
	upi: "UPI",
	wechat_pay: "WeChat Pay",
	wire_transfer: "Wire transfer",
	korea_local: "Korean payment methods",
};

const CARD_BRAND_LABELS: Record<string, string> = {
	american_express: "American Express",
	diners_club: "Diners Club",
	discover: "Discover",
	jcb: "JCB",
	mada: "Mada",
	maestro: "Maestro",
	mastercard: "Mastercard",
	union_pay: "UnionPay",
	unknown: "Card",
	visa: "Visa",
};

function formatUnknownType(type: string): string {
	return type
		.split("_")
		.map((word) => word.charAt(0).toUpperCase() + word.slice(1))
		.join(" ");
}

/**
 * Returns the full display label for a Paddle payment method.
 *
 * For card payments, pass `cardBrand` (from `method_details.card.type`) to
 * get the brand name, and `last4` (from `method_details.card.last4`) to
 * append the masked number. Both are optional — the label degrades gracefully.
 *
 * @param type - Paddle payment method type from `method_details.type`
 * @param cardBrand - Card brand from `method_details.card.type` (card payments only)
 * @param last4 - Last 4 digits from `method_details.card.last4` (card payments only)
 * @returns Human-readable payment method label
 *
 * @example
 * getPaymentMethodDisplay("card", "visa", "4242")    // "Visa ending 4242"
 * getPaymentMethodDisplay("card", "mastercard")       // "Mastercard"
 * getPaymentMethodDisplay("card")                     // "Card"
 * getPaymentMethodDisplay("paypal")                   // "PayPal"
 * getPaymentMethodDisplay("apple_pay")                // "Apple Pay"
 */
export function getPaymentMethodDisplay(
	type: PaddlePaymentMethodType,
	cardBrand?: PaddleCardType,
	last4?: string,
): string {
	if (type === "card") {
		const brand = cardBrand
			? (CARD_BRAND_LABELS[cardBrand] ?? formatUnknownType(cardBrand))
			: "Card";
		return last4 ? `${brand} ending ${last4}` : brand;
	}
	return PAYMENT_METHOD_LABELS[type] ?? formatUnknownType(type);
}
