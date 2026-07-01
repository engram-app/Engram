import { useSession, useSessionList } from "@clerk/react";
import type { SessionWithActivitiesResource } from "@clerk/shared/types";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { SettingsSectionCard } from "./section-card";

export function SessionsSection() {
	const { isLoaded, sessions } = useSessionList();
	const { session: active } = useSession();

	if (!isLoaded) return null;

	// `useSessionList()` is typed as `SessionResource[]`, but at runtime returns
	// session-with-activities resources carrying `latestActivity` + `revoke()`.
	const list = (sessions ?? []) as unknown as SessionWithActivitiesResource[];

	async function revoke(s: SessionWithActivitiesResource) {
		try {
			await s.revoke();
			toast.success("Session revoked");
		} catch {
			toast.error("Could not revoke");
		}
	}

	return (
		<SettingsSectionCard title="Active sessions" description="Devices signed in to your account.">
			<ul className="space-y-2">
				{list.map((s) => {
					const a = s.latestActivity;
					const name = `${a?.deviceType ?? "Device"} · ${a?.browserName ?? "Browser"}`;
					const isCurrent = s.id === active?.id;
					return (
						<li key={s.id} className="flex items-center justify-between gap-2 text-sm">
							<span className="text-foreground">
								{name}
								{isCurrent && (
									<span className="ml-2 rounded bg-muted px-1.5 py-0.5 text-xs text-muted-foreground">
										Current
									</span>
								)}
							</span>
							{!isCurrent && (
								<Button
									variant="ghost"
									size="sm"
									aria-label={`Revoke ${name}`}
									onClick={() => revoke(s)}
								>
									Revoke
								</Button>
							)}
						</li>
					);
				})}
			</ul>
		</SettingsSectionCard>
	);
}
