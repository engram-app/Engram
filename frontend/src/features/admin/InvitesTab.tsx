import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useState } from "react";
import { toast } from "sonner";
import { ApiError } from "@/api/client";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useT } from "@/i18n/locale-provider";
import { copyToClipboard } from "@/lib/clipboard";
import { intlLocale } from "@/lib/intl-locale";
import { adminApi, type Invite } from "./api";

const INVITES_KEY = ["admin", "invites"] as const;

export default function InvitesTab() {
	const { t, renderedLocale } = useT();
	const localeTag = intlLocale(renderedLocale);
	const qc = useQueryClient();
	const [label, setLabel] = useState("");
	const [maxUses, setMaxUses] = useState(1);
	const [days, setDays] = useState(7);
	const [creating, setCreating] = useState(false);
	// The raw URL is shown ONCE — backend never returns it again. Don't persist.
	const [lastUrl, setLastUrl] = useState<string | null>(null);

	// useQuery, not fetch-in-an-effect: the rest of the app already reads through
	// the query client, and the manual version had to mirror the response into
	// state from inside the effect.
	const invitesQuery = useQuery({
		queryKey: INVITES_KEY,
		queryFn: () => adminApi.listInvites(),
		// See MembersTab: the effect this replaced fetched on every mount.
		staleTime: 0,
	});
	const invites: Invite[] = invitesQuery.data?.invites ?? [];
	const loading = invitesQuery.isPending;

	const refresh = useCallback(() => qc.invalidateQueries({ queryKey: INVITES_KEY }), [qc]);

	async function create(e: React.FormEvent) {
		e.preventDefault();
		setCreating(true);
		try {
			const res = await adminApi.createInvite({
				label: label || undefined,
				max_uses: maxUses,
				expires_in_days: days,
			});
			setLastUrl(res.url);
			setLabel("");
			toast.success(t("Invite created — copy the link before leaving this page."));
			await refresh();
		} catch (err) {
			const msg = err instanceof ApiError ? err.message : t("Create failed");
			toast.error(msg);
		} finally {
			setCreating(false);
		}
	}

	async function revoke(id: string) {
		try {
			await adminApi.revokeInvite(id);
			toast.success(t("Invite revoked"));
			await refresh();
		} catch (err) {
			const msg = err instanceof ApiError ? err.message : t("Revoke failed");
			toast.error(msg);
		}
	}

	async function copy(url: string) {
		// Invites are the one flow an admin runs from a fresh self-host box, which
		// is exactly where navigator.clipboard is missing (non-secure origin).
		if (await copyToClipboard(url)) {
			toast.success(t("Copied to clipboard"));
		} else {
			toast.error(t("Could not copy"));
		}
	}

	return (
		<section className="space-y-6">
			<form onSubmit={create} className="grid grid-cols-1 gap-3 sm:grid-cols-[1fr_auto_auto_auto]">
				<label className="text-sm">
					<span className="mb-1 block font-medium text-muted-foreground text-xs">
						{t("Label (optional)")}
					</span>
					<Input
						type="text"
						placeholder={t("e.g. Mom")}
						value={label}
						onChange={(e) => setLabel(e.target.value)}
						className="w-full"
					/>
				</label>
				<label className="text-sm">
					<span className="mb-1 block font-medium text-muted-foreground text-xs">
						{t("Max uses")}
					</span>
					<Input
						type="number"
						min={1}
						value={maxUses}
						onChange={(e) => setMaxUses(Math.max(1, Number(e.target.value)))}
						className="w-20"
					/>
				</label>
				<label className="text-sm">
					<span className="mb-1 block font-medium text-muted-foreground text-xs">
						{t("Expires (days)")}
					</span>
					<Input
						type="number"
						min={0}
						value={days}
						onChange={(e) => setDays(Math.max(0, Number(e.target.value)))}
						className="w-24"
					/>
				</label>
				<Button type="submit" disabled={creating} className="self-end">
					{t("Create invite")}
				</Button>
			</form>

			{lastUrl ? (
				<aside
					className="rounded-md border border-primary/40 bg-primary/5 p-3 text-sm"
					role="status"
				>
					<p className="mb-2 font-medium text-foreground">
						{t("Share this link (shown once — not stored):")}
					</p>
					<div className="flex items-center gap-2">
						<code className="flex-1 overflow-x-auto rounded bg-background px-2 py-1 text-xs">
							{lastUrl}
						</code>
						<Button type="button" variant="outline" size="sm" onClick={() => copy(lastUrl)}>
							{t("Copy")}
						</Button>
						<Button type="button" variant="outline" size="sm" onClick={() => setLastUrl(null)}>
							{t("Done")}
						</Button>
					</div>
				</aside>
			) : null}

			{loading ? (
				<p className="text-muted-foreground text-sm">{t("Loading invites…")}</p>
			) : invitesQuery.error ? (
				<p role="alert" className="text-destructive text-sm">
					{invitesQuery.error instanceof ApiError
						? invitesQuery.error.message
						: t("Failed to load invites")}
				</p>
			) : invites.length === 0 ? (
				<p className="text-muted-foreground text-sm">{t("No active invites.")}</p>
			) : (
				<table className="w-full text-sm">
					<thead className="text-left text-muted-foreground text-xs">
						<tr>
							<th className="py-2 pr-2 font-medium">{t("Label")}</th>
							<th className="py-2 pr-2 font-medium">{t("Uses")}</th>
							<th className="py-2 pr-2 font-medium">{t("Expires")}</th>
							<th />
						</tr>
					</thead>
					<tbody>
						{invites.map((i) => (
							<tr key={i.id} className="border-border border-t">
								<td className="py-2 pr-2">{i.label ?? "—"}</td>
								<td className="py-2 pr-2">
									{i.use_count}/{i.max_uses}
								</td>
								<td className="py-2 pr-2">
									{i.expires_at ? new Date(i.expires_at).toLocaleDateString(localeTag) : t("never")}
								</td>
								<td className="py-2 text-right">
									<Button type="button" variant="destructive" onClick={() => revoke(i.id)}>
										{t("Revoke")}
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
