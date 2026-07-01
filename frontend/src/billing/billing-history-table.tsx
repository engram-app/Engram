import { Button } from "@/components/ui/button";
import type { BillingTransaction } from "../api/queries";
import { formatMoney } from "./format";

export default function BillingHistoryTable({
	transactions,
	onDownload,
	downloadingId = null,
}: {
	transactions: BillingTransaction[];
	onDownload: (id: string) => void;
	downloadingId?: string | null;
}) {
	return (
		<section className="space-y-4 rounded-lg border border-border bg-card p-6">
			<h2 className="font-semibold text-foreground text-lg">Billing history</h2>

			{transactions.length === 0 ? (
				<p className="text-muted-foreground text-sm">No transactions yet.</p>
			) : (
				<table className="w-full text-sm">
					<thead>
						<tr className="text-left text-muted-foreground">
							<th className="pb-2 font-medium">Date</th>
							<th className="pb-2 font-medium">Amount</th>
							<th className="pb-2 font-medium">Status</th>
							<th className="pb-2 text-right font-medium">Invoice</th>
						</tr>
					</thead>
					<tbody>
						{transactions.map((t) => (
							<tr key={t.id} className="border-border border-t">
								<td className="py-2">
									{t.billed_at ? new Date(t.billed_at).toLocaleDateString() : "—"}
								</td>
								<td className="py-2">{formatMoney(t.amount, t.currency) ?? "—"}</td>
								<td className="py-2 capitalize">{t.status.replace("_", " ")}</td>
								<td className="py-2 text-right">
									<Button
										variant="ghost"
										size="sm"
										onClick={() => onDownload(t.id)}
										disabled={downloadingId === t.id}
									>
										Download
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
