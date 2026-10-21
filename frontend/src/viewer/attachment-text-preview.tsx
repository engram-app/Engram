import { useEffect, useState } from "react";
import { useT } from "@/i18n/locale-provider";
import { parseCsv } from "./attachment-preview";

const MAX_ROWS = 500;

// Read-only text and CSV preview. The blob is already capped by
// TEXT_PREVIEW_MAX_BYTES, so reading it whole is bounded.
export function AttachmentTextPreview({
	blob,
	csv,
	filename,
}: {
	blob: Blob;
	csv: boolean;
	filename: string;
}) {
	const { t } = useT();
	const [text, setText] = useState<string | null>(null);

	useEffect(() => {
		let cancelled = false;
		blob.text().then((s) => {
			if (!cancelled) {
				setText(s);
			}
		});
		return () => {
			cancelled = true;
		};
	}, [blob]);

	if (text === null) {
		return null;
	}
	if (!csv) {
		return (
			<pre
				className="max-h-[70vh] overflow-auto rounded-lg border bg-muted/40 p-4 font-mono text-xs"
				translate="no"
			>
				{text}
			</pre>
		);
	}
	const rows = parseCsv(text, filename.toLowerCase().endsWith(".tsv") ? "\t" : ",", MAX_ROWS + 1);
	const [head, ...body] = rows;
	return (
		<figure className="flex flex-col gap-1">
			<div className="max-h-[70vh] overflow-auto rounded-lg border">
				<table className="w-full text-xs" translate="no">
					{head ? (
						<thead className="sticky top-0 bg-muted">
							<tr>
								{head.map((h, i) => (
									// biome-ignore lint/suspicious/noArrayIndexKey: columns have no identity beyond position.
									<th key={i} className="border-b px-2 py-1 text-left font-medium">
										{h}
									</th>
								))}
							</tr>
						</thead>
					) : null}
					<tbody>
						{body.slice(0, MAX_ROWS - 1).map((r, i) => (
							// biome-ignore lint/suspicious/noArrayIndexKey: rows have no identity beyond position.
							<tr key={i} className="even:bg-muted/30">
								{r.map((c, j) => (
									// biome-ignore lint/suspicious/noArrayIndexKey: columns have no identity beyond position.
									<td key={j} className="px-2 py-1 align-top">
										{c}
									</td>
								))}
							</tr>
						))}
					</tbody>
				</table>
			</div>
			{rows.length > MAX_ROWS ? (
				<figcaption className="text-muted-foreground text-xs">
					{t("Showing the first {count} rows.", { count: MAX_ROWS })}
				</figcaption>
			) : null}
		</figure>
	);
}
