import { useSession, useSessionList } from "@clerk/react";
import type { SessionResource, SessionWithActivitiesResource } from "@clerk/shared/types";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { SettingsSectionCard } from "./section-card";

function hasActivities(s: SessionResource): s is SessionResource & SessionWithActivitiesResource {
	// Only revoke() is required. `latestActivity` comes from the CDN-loaded
	// clerk-js runtime, which nothing in this repo can typecheck or test, and the
	// row below already falls back to "Device · Browser" without it — gating on
	// it would empty the whole list (and the ability to sign other devices out)
	// the first time a Clerk build set it conditionally.
	return "revoke" in s && typeof s.revoke === "function";
}

export function SessionsSection() {
	const { isLoaded, sessions } = useSessionList();
	const { session: active } = useSession();

	if (!isLoaded) {
		return null;
	}

	// `useSessionList()` is typed as `SessionResource[]`, but at runtime returns
	// session-with-activities resources carrying `latestActivity` + `revoke()`.
	// Checked rather than declared, so a Clerk build that stops sending revoke()
	// drops that row instead of throwing when the button is pressed.
	const list = (sessions ?? []).filter(hasActivities);

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
									<span className="ml-2 rounded bg-muted px-1.5 py-0.5 text-muted-foreground text-xs">
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
