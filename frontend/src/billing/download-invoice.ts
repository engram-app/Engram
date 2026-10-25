import type { Translate } from "@/i18n/translate";
import { notify } from "@/lib/notify";
import { ApiError, api } from "../api/client";

export async function downloadInvoice(transactionId: string, t: Translate) {
	try {
		const { url } = await api.get<{ url: string }>(
			`/billing/transactions/${transactionId}/invoice`,
		);
		window.open(url, "_blank", "noopener");
	} catch (err) {
		// 404: Paddle has no invoice for this transaction ($0, e.g. a trial
		// start). Retrying cannot help, so don't suggest it.
		if (err instanceof ApiError && err.status === 404) {
			notify.error(t("No invoice is available for this transaction."));
		} else {
			notify.error(t("Could not fetch that invoice. Please try again."));
		}
	}
}
