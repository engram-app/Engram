import { Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import type { PaymentMethod } from "../api/queries";

function formatExpiry(month: number | null, year: number | null): string | null {
	if (!(month && year)) {
		return null;
	}
	return `${String(month).padStart(2, "0")}/${year}`;
}

export default function PaymentMethodCard({
	paymentMethod,
	onUpdate,
	updating = false,
}: {
	paymentMethod: PaymentMethod | null;
	onUpdate: () => void;
	updating?: boolean;
}) {
	const { t } = useT();
	const expiry = formatExpiry(paymentMethod?.exp_month ?? null, paymentMethod?.exp_year ?? null);

	return (
		<section className="space-y-4 rounded-lg border border-border bg-card p-6">
			<header className="flex items-center justify-between">
				<h2 className="font-semibold text-foreground text-lg">{t("Payment method")}</h2>
				<Button variant="outline" size="sm" onClick={onUpdate} disabled={updating}>
					{Boolean(updating) && <Loader2 aria-hidden className="size-3 animate-spin" />}
					{updating ? t("Opening…") : t("Update")}
				</Button>
			</header>

			{paymentMethod?.last4 ? (
				<p className="text-muted-foreground text-sm">
					<span className="font-medium text-foreground capitalize">{paymentMethod.card_brand}</span>
					••••
					{paymentMethod.last4}
					{expiry && <span> · {t("expires {expiry}", { expiry })}</span>}
				</p>
			) : (
				<p className="text-muted-foreground text-sm">{t("No payment method on file.")}</p>
			)}
		</section>
	);
}
