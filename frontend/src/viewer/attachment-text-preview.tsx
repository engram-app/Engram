import { useEffect, useState } from "react";
import { ScrollArea, ScrollBar } from "@/components/ui/scroll-area";
import { useT } from "@/i18n/locale-provider";
import { intlLocale } from "@/lib/intl-locale";
import { formatBytes, parseCsv, TEXT_PREVIEW_MAX_BYTES } from "./attachment-preview";

const MAX_ROWS = 500;

// Read-only text and CSV preview. Only the first TEXT_PREVIEW_MAX_BYTES are
// read and rendered: "Preview anyway" can hand this a much larger file, and a
// <pre> holding 100 MB of text freezes the tab.
export function AttachmentTextPreview({
	blob,
	csv,
	filename,
}: {
	blob: Blob;
	csv: boolean;
	filename: string;
}) {
	const { t, renderedLocale } = useT();
	const truncated = blob.size > TEXT_PREVIEW_MAX_BYTES;
	const [text, setText] = useState<string | null>(null);

	useEffect(() => {
		let cancelled = false;
		blob
			.slice(0, TEXT_PREVIEW_MAX_BYTES)
			.text()
			.then((s) => {
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
			<figure className="flex flex-col gap-1">
				<ScrollArea
					className="rounded-lg border bg-muted/40"
					viewportClassName="max-h-[70vh]"
					viewportLabel={filename}
				>
					{/* w-max: long lines scroll sideways instead of wrapping. */}
					<pre className="w-max min-w-full p-4 font-mono text-xs" translate="no">
						{text}
					</pre>
					<ScrollBar orientation="horizontal" />
				</ScrollArea>
				{truncated ? (
					<figcaption className="text-muted-foreground text-xs">
						{t("Showing the first {size}.", {
							size: formatBytes(TEXT_PREVIEW_MAX_BYTES, intlLocale(renderedLocale)),
						})}
					</figcaption>
				) : null}
			</figure>
		);
	}
	const rows = parseCsv(text, filename.toLowerCase().endsWith(".tsv") ? "\t" : ",", MAX_ROWS + 1);
	const [head, ...body] = rows;
	return (
		<figure className="flex flex-col gap-1">
			<ScrollArea
				className="rounded-lg border"
				viewportClassName="max-h-[70vh]"
				viewportLabel={filename}
			>
				{/* w-max: wide tables scroll sideways; min-w-full: narrow ones fill. */}
				<table className="w-max min-w-full text-xs" translate="no">
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
				<ScrollBar orientation="horizontal" />
			</ScrollArea>
			{rows.length > MAX_ROWS ? (
				<figcaption className="text-muted-foreground text-xs">
					{t("Showing the first {count} rows.", { count: MAX_ROWS })}
				</figcaption>
			) : null}
		</figure>
	);
}
