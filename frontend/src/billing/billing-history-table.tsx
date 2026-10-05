import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import type { BillingTransaction } from "../api/queries";
import { formatMoney, statusLabel } from "./format";

export default function BillingHistoryTable({
	transactions,
	onDownload,
	downloadingId = null,
}: {
	transactions: BillingTransaction[];
	onDownload: (id: string) => void;
	downloadingId?: string | null;
}) {
	const { t } = useT();
	return (
		<section className="space-y-4 rounded-lg border border-border bg-card p-6">
			<h2 className="font-semibold text-foreground text-lg">{t("Billing history")}</h2>

			{transactions.length === 0 ? (
				<p className="text-muted-foreground text-sm">{t("No transactions yet.")}</p>
			) : (
				<table className="w-full text-sm">
					<thead>
						<tr className="text-left text-muted-foreground">
							<th className="pb-2 font-medium">{t("Date")}</th>
							<th className="pb-2 font-medium">{t("Amount")}</th>
							<th className="pb-2 font-medium">{t("Status")}</th>
							<th className="pb-2 text-right font-medium">{t("Invoice")}</th>
						</tr>
					</thead>
					<tbody>
						{transactions.map((txn) => (
							<tr key={txn.id} className="border-border border-t">
								<td className="py-2">
									{txn.billed_at ? new Date(txn.billed_at).toLocaleDateString() : "—"}
								</td>
								<td className="py-2">{formatMoney(txn.amount, txn.currency) ?? "—"}</td>
								<td className="py-2 capitalize">{statusLabel(txn.status, t)}</td>
								<td className="py-2 text-right">
									<Button
										variant="ghost"
										size="sm"
										onClick={() => onDownload(txn.id)}
										disabled={downloadingId === txn.id}
									>
										{t("Download")}
									</Button>
								</td>
							</tr>
						))}
					</tbody>
				</table>
			)}
		</section>
	);
}
