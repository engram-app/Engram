import * as React from "react";
import type { PaddlePaymentMethodType, PaddleCardType } from "./paddle-payment-method-display";

// --- Brand icon components ---

function VisaIcon({ className }: { className?: string }) {
	return (
		<svg viewBox="0 0 38 24" className={className} aria-hidden="true">
			<rect width="38" height="24" rx="4" fill="currentColor" fillOpacity="0.08" />
			<path
				d="M16.5 7.5L14.1 16.5H11.7L14.1 7.5H16.5ZM26.4 13.5L27.6 10.1L28.3 13.5H26.4ZM29.1 16.5H31.3L29.4 7.5H27.4C26.9 7.5 26.5 7.8 26.3 8.2L22.8 16.5H25.3L25.8 15.1H28.8L29.1 16.5ZM23.1 13.5C23.1 11.1 19.7 11 19.7 9.9C19.7 9.6 20 9.2 20.7 9.1C21 9.1 22 9 23.1 9.5L23.5 7.8C22.9 7.6 22.1 7.4 21.1 7.4C18.7 7.4 17.1 8.7 17.1 10.5C17.1 11.9 18.4 12.6 19.3 13.1C20.3 13.5 20.6 13.8 20.6 14.2C20.6 14.8 19.9 15.1 19.2 15.1C18 15.1 17.3 14.8 16.7 14.5L16.3 16.3C16.9 16.6 18 16.8 19.1 16.8C21.6 16.8 23.1 15.5 23.1 13.5Z"
				fill="currentColor"
			/>
		</svg>
	);
}

function MastercardIcon({ className }: { className?: string }) {
	return (
		<svg viewBox="0 0 38 24" className={className} aria-hidden="true">
			<rect width="38" height="24" rx="4" fill="currentColor" fillOpacity="0.08" />
			<circle cx="15" cy="12" r="5" fill="currentColor" fillOpacity="0.6" />
			<circle cx="23" cy="12" r="5" fill="currentColor" fillOpacity="0.4" />
		</svg>
	);
}

function AmexIcon({ className }: { className?: string }) {
	return (
		<svg viewBox="0 0 38 24" className={className} aria-hidden="true">
			<rect width="38" height="24" rx="4" fill="currentColor" fillOpacity="0.08" />
			<text
				x="19"
				y="16"
				textAnchor="middle"
				fontSize="8"
				fontWeight="700"
				fill="currentColor"
				fontFamily="sans-serif"
			>
				AMEX
			</text>
		</svg>
	);
}

function PayPalIcon({ className }: { className?: string }) {
	return (
		<svg viewBox="0 0 38 24" className={className} aria-hidden="true">
			<rect width="38" height="24" rx="4" fill="currentColor" fillOpacity="0.08" />
			<text
				x="19"
				y="16"
				textAnchor="middle"
				fontSize="7"
				fontWeight="700"
				fill="currentColor"
				fontFamily="sans-serif"
			>
				PayPal
			</text>
		</svg>
	);
}

function ApplePayIcon({ className }: { className?: string }) {
	return (
		<svg viewBox="0 0 38 24" className={className} aria-hidden="true">
			<rect width="38" height="24" rx="4" fill="currentColor" fillOpacity="0.08" />
			<path
				d="M19 7.5C18 7.5 17.2 8 16.7 8.7C16.2 8.1 15.4 7.5 14.4 7.5C12.6 7.5 11.2 9 11.2 11C11.2 14 14.4 16.5 15.6 16.5C16.1 16.5 16.6 16.2 17 16.2C17.4 16.2 17.9 16.5 18.4 16.5C19.6 16.5 22.8 14 22.8 11C22.8 9 21.4 7.5 19 7.5Z"
				fill="currentColor"
				fillOpacity="0.7"
			/>
		</svg>
	);
}

function GooglePayIcon({ className }: { className?: string }) {
	return (
		<svg viewBox="0 0 38 24" className={className} aria-hidden="true">
			<rect width="38" height="24" rx="4" fill="currentColor" fillOpacity="0.08" />
			<text
				x="19"
				y="16"
				textAnchor="middle"
				fontSize="7"
				fontWeight="700"
				fill="currentColor"
				fontFamily="sans-serif"
			>
				GPay
			</text>
		</svg>
	);
}

// --- Lookup ---

const CARD_BRAND_ICONS: Record<string, React.ElementType> = {
	visa: VisaIcon,
	mastercard: MastercardIcon,
	american_express: AmexIcon,
};

const PAYMENT_METHOD_ICONS: Record<string, React.ElementType> = {
	paypal: PayPalIcon,
	apple_pay: ApplePayIcon,
	google_pay: GooglePayIcon,
};

/**
 * Returns an icon component for the given Paddle payment method type and optional card brand.
 * Returns `null` when no branded icon is available — callers should fall back to a generic icon.
 */
export function getPaymentMethodIcon(
	type: PaddlePaymentMethodType,
	cardBrand?: PaddleCardType,
): React.ElementType | null {
	if (type === "card" && cardBrand) {
		return CARD_BRAND_ICONS[cardBrand] ?? null;
	}
	return PAYMENT_METHOD_ICONS[type] ?? null;
}
