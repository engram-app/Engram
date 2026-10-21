import { Shapes } from "lucide-react";
import { useEffect, useState } from "react";
import { ScrollArea, ScrollBar } from "@/components/ui/scroll-area";
import { useT } from "@/i18n/locale-provider";
import { intlLocale } from "@/lib/intl-locale";
import {
	excalidrawTexts,
	formatBytes,
	parseCsv,
	readTextHead,
	TEXT_PREVIEW_MAX_BYTES,
} from "./attachment-preview";

// Data rows shown, not counting the header.
const MAX_ROWS = 500;

// Read-only text and CSV preview. Only the first TEXT_PREVIEW_MAX_BYTES are
// rendered: a <pre> holding 100 MB of text freezes the tab. The page fetches
// one byte more than that, so a blob past the cap means the file was cut.
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
		readTextHead(blob, TEXT_PREVIEW_MAX_BYTES).then((s) => {
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
			<figure className="flex min-h-0 flex-1 flex-col gap-1">
				<ScrollArea
					className="min-h-0 flex-1 rounded-lg border bg-muted/40"
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
	const rows = parseCsv(text, filename.toLowerCase().endsWith(".tsv") ? "\t" : ",", MAX_ROWS + 2);
	const [head, ...body] = rows;
	return (
		<figure className="flex min-h-0 flex-1 flex-col gap-1">
			<ScrollArea className="min-h-0 flex-1 rounded-lg border" viewportLabel={filename}>
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
						{body.slice(0, MAX_ROWS).map((r, i) => (
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
			{body.length > MAX_ROWS ? (
				<figcaption className="text-muted-foreground text-xs">
					{t("Showing the first {count} rows.", { count: MAX_ROWS })}
				</figcaption>
			) : null}
		</figure>
	);
}

// We do not render Excalidraw drawings (its renderer is a very large
// dependency), so say what the file is, where it opens, and the words in it.
export function ExcalidrawPreview({ blob }: { blob: Blob }) {
	const { t } = useT();
	const [texts, setTexts] = useState<string[] | null>(null);

	useEffect(() => {
		let cancelled = false;
		readTextHead(blob, TEXT_PREVIEW_MAX_BYTES).then((s) => {
			if (!cancelled) {
				setTexts(excalidrawTexts(s));
			}
		});
		return () => {
			cancelled = true;
		};
	}, [blob]);

	return (
		<section className="flex flex-col items-center gap-3 rounded-lg border border-dashed px-6 py-12 text-center">
			<Shapes className="size-10 text-muted-foreground" aria-hidden="true" />
			<h3 className="font-medium">{t("Excalidraw drawing")}</h3>
			<p className="max-w-md text-muted-foreground text-sm">
				{t("Open it in Obsidian with the Excalidraw plugin to see and edit the drawing.")}
			</p>
			{texts && texts.length > 0 ? (
				<figure className="mt-2 flex max-w-md flex-col gap-1 text-sm">
					<figcaption className="text-muted-foreground text-xs">
						{t("Text in this drawing")}
					</figcaption>
					<ul translate="no">
						{texts.map((text, i) => (
							// biome-ignore lint/suspicious/noArrayIndexKey: the same words can repeat; position is the only identity.
							<li key={i}>{text}</li>
						))}
					</ul>
				</figure>
			) : null}
		</section>
	);
}
