import { useState } from "react";
import { toast } from "sonner";
import { useMe } from "@/api/queries";
import { useConfig } from "@/config-context";
import InvitesTab from "./InvitesTab";
import MembersTab from "./MembersTab";
import RegistrationTab from "./RegistrationTab";

export default function AdminPanel() {
	const config = useConfig();
	const { data: me, isLoading } = useMe();
	// Lifted from MembersTab so the one-time reset link sits OUTSIDE the
	// Members card — its own standalone block above the table.
	const [resetUrl, setResetUrl] = useState<string | null>(null);

	async function copyResetUrl() {
		if (!resetUrl) {
			return;
		}
		await navigator.clipboard.writeText(resetUrl);
		toast.success("Copied to clipboard");
	}

	// Defensive gate — the nav entry is hidden when these don't hold, but a user
	// hitting the URL directly should still get a clean denial rather than a
	// confusing partial page that 403s on every request.
	if (config.authProvider !== "local") {
		return (
			<p className="text-muted-foreground text-sm">
				Administration is only available on self-hosted instances.
			</p>
		);
	}

	if (isLoading || !me) {
		return <p className="text-muted-foreground text-sm">Loading…</p>;
	}

	if (me.role !== "admin") {
		return (
			<p className="text-muted-foreground text-sm">
				You don't have administrator access on this instance.
			</p>
		);
	}

	return (
		<article className="space-y-10">
			<header>
				<h1 className="font-semibold text-foreground text-xl">Administration</h1>
				<p className="mt-1 text-muted-foreground text-sm">
					Manage members, invite links, and who can create accounts on this instance.
				</p>
			</header>

			<section aria-labelledby="members-heading" className="space-y-3">
				<h2 id="members-heading" className="font-semibold text-foreground text-sm">
					Members
				</h2>

				{resetUrl && (
					<aside
						className="rounded-lg border border-primary/40 bg-primary/5 p-4 text-sm"
						role="status"
					>
						<p className="mb-2 font-medium text-foreground">
							One-time reset link (shown once — not stored):
						</p>
						<div className="flex items-center gap-2">
							<code className="flex-1 overflow-x-auto rounded bg-background px-2 py-1.5 text-xs">
								{resetUrl}
							</code>
							<button
								type="button"
								onClick={copyResetUrl}
								className="shrink-0 rounded-md border border-border bg-background px-3 py-1.5 font-medium text-xs hover:bg-accent"
							>
								Copy
							</button>
							<button
								type="button"
								onClick={() => setResetUrl(null)}
								className="shrink-0 rounded-md border border-border bg-background px-3 py-1.5 font-medium text-xs hover:bg-accent"
							>
								Done
							</button>
						</div>
					</aside>
				)}

				<div className="overflow-hidden rounded-lg border border-border bg-card">
					<MembersTab currentUserId={me.id} onResetIssued={setResetUrl} />
				</div>
			</section>

			<section aria-labelledby="invites-heading" className="space-y-3">
				<h2 id="invites-heading" className="font-semibold text-foreground text-sm">
					Invites
				</h2>
				<div className="rounded-lg border border-border bg-card p-4 sm:p-6">
					<InvitesTab />
				</div>
			</section>

			<section aria-labelledby="registration-heading" className="space-y-3">
				<h2 id="registration-heading" className="font-semibold text-foreground text-sm">
					Registration
				</h2>
				<div className="rounded-lg border border-border bg-card p-4 sm:p-6">
					<RegistrationTab />
				</div>
			</section>
		</article>
	);
}
