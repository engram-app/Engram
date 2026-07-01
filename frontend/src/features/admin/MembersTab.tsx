import { ChevronRight, Loader2 } from "lucide-react";
import { Fragment, useEffect, useState } from "react";
import { toast } from "sonner";
import { ApiError } from "@/api/client";
import { cn } from "@/lib/utils";
import { adminApi, type AdminUser } from "./api";

// Stable button surface for the row's actions: instant active feedback
// (active:scale-[0.97]), an inline spinner while the request is in flight,
// and a destructive red-outline variant. Same width whether busy or not so
// the layout doesn't shift mid-click.
function ActionButton({
	onClick,
	disabled,
	busy,
	variant = "default",
	title,
	children,
}: {
	onClick: () => void;
	disabled?: boolean;
	busy?: boolean;
	variant?: "default" | "destructive";
	title?: string;
	children: React.ReactNode;
}) {
	return (
		<button
			type="button"
			onClick={onClick}
			disabled={disabled}
			title={title}
			className={cn(
				"inline-flex shrink-0 items-center gap-1.5 whitespace-nowrap rounded-md border px-3 py-1.5 text-xs font-medium",
				"transition-[transform,background-color,opacity] active:scale-[0.97]",
				"disabled:cursor-not-allowed disabled:opacity-50 disabled:active:scale-100",
				variant === "destructive"
					? "border-destructive/40 bg-background text-destructive hover:bg-destructive/10 disabled:border-border disabled:text-muted-foreground disabled:hover:bg-background"
					: "border-border bg-background hover:bg-accent disabled:hover:bg-background",
			)}
		>
			{busy && <Loader2 aria-hidden className="size-3 animate-spin" />}
			{children}
		</button>
	);
}

export default function MembersTab({
	currentUserId,
	onResetIssued,
}: {
	currentUserId: string;
	// Lifted to AdminPanel so the one-time reset-link banner can sit OUTSIDE
	// the Members card — above it, where it's visually separated.
	onResetIssued: (url: string) => void;
}) {
	const [users, setUsers] = useState<AdminUser[]>([]);
	const [loading, setLoading] = useState(true);
	const [pendingDelete, setPendingDelete] = useState<string | null>(null);
	// One open at a time keeps the table calm. null = all collapsed.
	const [expandedId, setExpandedId] = useState<string | null>(null);
	// Per-user in-flight action: disables that row's buttons + shows a
	// spinner on the active one, so feedback is instant on click even
	// while the request is in flight.
	const [pending, setPending] = useState<Record<string, "role" | "suspend" | "reset" | "delete">>(
		{},
	);

	function sortUsers(list: AdminUser[]): AdminUser[] {
		return [...list].sort((a, b) => {
			if (a.id === currentUserId) return -1;
			if (b.id === currentUserId) return 1;
			return 0;
		});
	}

	async function refresh() {
		try {
			const res = await adminApi.listUsers();
			setUsers(sortUsers(res.users));
		} catch (e) {
			toast.error(e instanceof ApiError ? e.message : "Failed to load users");
		} finally {
			setLoading(false);
		}
	}

	useEffect(() => {
		refresh();
	}, []);

	// Optimistic mutation: patch the local row immediately so the UI
	// reflects the intent on the next paint. On success we refresh from
	// the server to canonicalize; on failure refresh also rolls us back.
	async function optimistic<T>(
		id: string,
		kind: "role" | "suspend" | "reset" | "delete",
		label: string,
		patch: Partial<AdminUser> | "remove",
		fn: () => Promise<T>,
	) {
		const snapshot = users;
		setPending((p) => ({ ...p, [id]: kind }));
		if (patch === "remove") {
			setUsers((prev) => prev.filter((u) => u.id !== id));
		} else {
			setUsers((prev) => prev.map((u) => (u.id === id ? { ...u, ...patch } : u)));
		}
		try {
			await fn();
			await refresh();
		} catch (e) {
			setUsers(snapshot); // explicit rollback before refresh races
			const raw = e instanceof ApiError ? e.message : "unknown error";
			const friendly = raw === "last_admin" ? "Can't remove the last admin." : raw;
			toast.error(`${label}: ${friendly}`);
		} finally {
			setPending((p) => {
				const next = { ...p };
				delete next[id];
				return next;
			});
		}
	}

	function toggleRole(u: AdminUser) {
		const next = u.role === "admin" ? "member" : "admin";
		return optimistic(u.id, "role", "Update role", { role: next }, () =>
			adminApi.updateUser(u.id, { role: next }),
		);
	}

	function toggleSuspend(u: AdminUser) {
		return optimistic(u.id, "suspend", "Update status", { suspended: !u.suspended }, () =>
			adminApi.updateUser(u.id, { suspended: !u.suspended }),
		);
	}

	function remove(u: AdminUser) {
		setPendingDelete(null);
		return optimistic(u.id, "delete", "Delete user", "remove", () => adminApi.deleteUser(u.id));
	}

	async function issueReset(u: AdminUser) {
		setPending((p) => ({ ...p, [u.id]: "reset" }));
		try {
			const { url } = await adminApi.issueReset(u.id);
			onResetIssued(url);
		} catch (e) {
			toast.error(e instanceof ApiError ? e.message : "Reset link failed");
		} finally {
			setPending((p) => {
				const next = { ...p };
				delete next[u.id];
				return next;
			});
		}
	}

	function toggleExpanded(id: string) {
		setExpandedId((cur) => (cur === id ? null : id));
		setPendingDelete(null);
	}

	return (
		<section>
			{loading ? (
				<p className="p-4 text-sm text-muted-foreground">Loading…</p>
			) : users.length === 0 ? (
				<p className="p-4 text-sm text-muted-foreground">No users.</p>
			) : (
				<table className="w-full text-sm">
					<thead className="text-left text-xs text-muted-foreground">
						<tr>
							<th className="py-3 pl-4 pr-2 font-medium">Email</th>
							<th className="py-3 pr-2 font-medium">Role</th>
							<th className="py-3 pr-2 font-medium">Status</th>
							<th className="py-3 pr-2 font-medium">Last active</th>
							<th className="w-10" />
						</tr>
					</thead>
					<tbody>
						{users.map((u) => {
							const isSelf = u.id === currentUserId;
							const isExpanded = expandedId === u.id;
							return (
								<Fragment key={u.id}>
									<tr
										className={cn(
											"cursor-pointer border-t border-border transition-colors",
											isSelf && "bg-primary/5",
											isExpanded ? "bg-accent/50" : "hover:bg-accent/30",
										)}
										onClick={() => toggleExpanded(u.id)}
									>
										<td className="py-3 pl-4 pr-2">
											<span className="text-foreground">{u.email}</span>
											{isSelf && (
												<span className="ml-2 rounded-sm bg-primary/15 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wider text-primary">
													you
												</span>
											)}
										</td>
										<td className="py-3 pr-2">{u.role}</td>
										<td className="py-3 pr-2">
											{u.suspended ? <span className="text-destructive">suspended</span> : "active"}
										</td>
										<td className="py-3 pr-2">
											{u.last_active ? new Date(u.last_active).toLocaleDateString() : "—"}
										</td>
										<td className="py-3 pl-2 pr-4 text-right">
											<ChevronRight
												aria-hidden
												strokeWidth={2.5}
												className={cn(
													"inline-block size-5 text-muted-foreground transition-transform duration-150",
													isExpanded && "rotate-90 text-foreground",
												)}
											/>
										</td>
									</tr>
									{isExpanded && (
										<tr className="border-t border-border bg-accent/20">
											<td colSpan={5} className="px-4 py-4">
												{pendingDelete === u.id ? (
													<div className="flex flex-wrap items-center justify-between gap-3">
														<span className="text-xs text-muted-foreground">
															Delete {u.email} + their vault data?
														</span>
														<div className="flex items-center gap-2">
															<button
																type="button"
																onClick={() => setPendingDelete(null)}
																className="rounded-md border border-border bg-background px-3 py-1.5 text-xs font-medium hover:bg-accent"
															>
																Cancel
															</button>
															<button
																type="button"
																onClick={() => remove(u)}
																className="rounded-md bg-destructive px-3 py-1.5 text-xs font-semibold text-white shadow-sm hover:bg-destructive/90"
															>
																Confirm delete
															</button>
														</div>
													</div>
												) : (
													<div className="flex flex-wrap items-center justify-between gap-3">
														<div className="flex flex-wrap items-center gap-2">
															<ActionButton
																onClick={() => toggleRole(u)}
																disabled={isSelf || u.id in pending}
																busy={pending[u.id] === "role"}
																title={isSelf ? "Cannot change your own role" : undefined}
															>
																{u.role === "admin" ? "Demote to member" : "Promote to admin"}
															</ActionButton>
															<ActionButton
																onClick={() => issueReset(u)}
																disabled={u.id in pending}
																busy={pending[u.id] === "reset"}
															>
																Reset password
															</ActionButton>
														</div>
														<div className="flex flex-wrap items-center gap-2">
															<ActionButton
																variant="destructive"
																onClick={() => toggleSuspend(u)}
																disabled={isSelf || u.id in pending}
																busy={pending[u.id] === "suspend"}
																title={isSelf ? "Cannot suspend yourself" : undefined}
															>
																{u.suspended ? "Unsuspend" : "Suspend"}
															</ActionButton>
															{!isSelf && (
																<ActionButton
																	variant="destructive"
																	onClick={() => setPendingDelete(u.id)}
																	disabled={u.id in pending}
																>
																	Delete user
																</ActionButton>
															)}
														</div>
													</div>
												)}
											</td>
										</tr>
									)}
								</Fragment>
							);
						})}
					</tbody>
				</table>
			)}
		</section>
	);
}
