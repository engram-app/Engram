import { useQuery } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { Link, useSearchParams } from "react-router";
import { api } from "@/api/client";
import { useMe } from "@/api/queries";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useT } from "@/i18n/locale-provider";
import { heading } from "@/lib/ui-classes";
import LoadingPane from "@/viewer/loading-pane";

// Operator insights (Engram.Insights). Only an operator account sees it;
// everyone else gets the ordinary 404 page, so the route stays invisible.
// The server enforces the same rule on /api/operator/insights.
//
// ponytail: one generic renderer for every report (scalars as a list,
// arrays of rows as a table, counts as <meter> bars). Give a report its
// own view when the generic one stops being readable.

type Json = string | number | boolean | null | Json[] | { [key: string]: Json };

const BASE = "/operator/insights";

function Value({ value }: { value: Json }) {
	if (Array.isArray(value)) {
		return isRows(value) ? <Rows rows={value} /> : value.map(String).join(", ");
	}
	if (value !== null && typeof value === "object") {
		return (
			<dl className="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-2 text-sm">
				{Object.entries(value).map(([key, v]) => (
					<Entry key={key} name={key} value={v} />
				))}
			</dl>
		);
	}
	return <>{value === null ? "" : String(value)}</>;
}

function Entry({ name, value }: { name: string; value: Json }) {
	return (
		<>
			<dt className="font-medium">{name}</dt>
			<dd className="overflow-x-auto">
				<Value value={value} />
			</dd>
		</>
	);
}

function isRows(value: Json[]): value is { [key: string]: Json }[] {
	return (
		value.length > 0 &&
		value.every((row) => row !== null && typeof row === "object" && !Array.isArray(row))
	);
}

// A table of rows. A numeric column also draws a bar per row, scaled to the
// column's largest value. A `user_id` cell links to that user's timeline.
function Rows({ rows }: { rows: { [key: string]: Json }[] }) {
	const columns = [...new Set(rows.flatMap(Object.keys))];
	const max = (col: string) =>
		Math.max(
			0,
			...rows.map((r) => {
				const v = r[col];
				return typeof v === "number" ? v : 0;
			}),
		);

	return (
		<table className="w-full text-left text-sm">
			<thead>
				<tr>
					{columns.map((col) => (
						<th key={col} className="px-2 py-1 font-medium">
							{col}
						</th>
					))}
				</tr>
			</thead>
			<tbody>
				{rows.map((row) => (
					// Rows carry no id; every report row differs in some column.
					<tr key={JSON.stringify(row)} className="border-border border-t align-top">
						{columns.map((col) => (
							<td key={col} className="px-2 py-1">
								<Cell column={col} value={row[col] ?? null} max={max(col)} />
							</td>
						))}
					</tr>
				))}
			</tbody>
		</table>
	);
}

function Cell({ column, value, max }: { column: string; value: Json; max: number }) {
	if (column === "user_id" && typeof value === "string") {
		return (
			<Link to={`?user=${value}`} className="font-mono text-xs underline">
				{value}
			</Link>
		);
	}
	if (typeof value === "number" && max > 0) {
		return (
			<span className="flex items-center gap-2">
				<meter min={0} max={max} value={value} className="w-24" />
				{value}
			</span>
		);
	}
	return <Value value={value} />;
}

function OperatorInsightsPage({ notFound }: { notFound: ReactNode }) {
	const { t } = useT();
	const me = useMe();
	const [params] = useSearchParams();
	const isOperator = me.data?.role === "operator";
	const reports = useQuery({
		queryKey: ["operator-insights"],
		queryFn: () => api.get<{ reports: string[] }>(BASE),
		enabled: isOperator,
	});
	const userId = params.get("user");
	const report = params.get("report") ?? reports.data?.reports[0];
	const path = userId ? `${BASE}/users/${userId}` : report && `${BASE}/${report}`;
	const data = useQuery({
		queryKey: ["operator-insights", path],
		queryFn: () => api.get<Json>(path ?? ""),
		enabled: isOperator && Boolean(path),
	});

	if (me.isLoading) {
		return <LoadingPane />;
	}
	if (!isOperator) {
		return notFound;
	}

	return (
		<main className="mx-auto flex max-w-6xl flex-col gap-6 p-6">
			<h1 className={heading}>{t("Customer insights")}</h1>
			<nav>
				<ul className="flex flex-wrap gap-3 text-sm">
					{reports.data?.reports.map((name) => (
						<li key={name}>
							<Link
								to={`?report=${name}`}
								aria-current={!userId && name === report ? "page" : undefined}
								className="underline-offset-4 hover:underline aria-[current=page]:font-bold"
							>
								{name}
							</Link>
						</li>
					))}
				</ul>
			</nav>
			<form method="get" className="flex max-w-md gap-2">
				<label className="flex flex-1 items-center gap-2 text-sm">
					{t("User ID")}
					<Input name="user" defaultValue={userId ?? ""} required />
				</label>
				<Button type="submit" variant="outline" size="sm">
					{t("Show timeline")}
				</Button>
			</form>
			{data.isLoading ? <LoadingPane /> : null}
			{data.isError ? <p role="alert">{t("Failed to load the report.")}</p> : null}
			{data.data !== undefined && <Value value={data.data} />}
		</main>
	);
}

export default OperatorInsightsPage;
