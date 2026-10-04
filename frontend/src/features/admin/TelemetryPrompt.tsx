import { useEffect, useState } from "react";
import { toast } from "sonner";
import { ApiError } from "@/api/client";
import { useMe } from "@/api/queries";
import { useConfig } from "@/config-context";
import { adminApi } from "./api";

function AdminTelemetryPrompt() {
	const { data: me } = useMe();
	const isAdmin = me?.role === "admin";
	const [pending, setPending] = useState(false);
	const [saving, setSaving] = useState(false);

	useEffect(() => {
		if (!isAdmin) {
			return;
		}
		adminApi
			.getTelemetry()
			// Nothing would be sent while the environment forbids it, so don't ask.
			.then((s) => setPending(s.telemetry_enabled === null && !s.env_disabled))
			.catch(() => setPending(false));
	}, [isAdmin]);

	async function answer(enabled: boolean) {
		if (saving) {
			return;
		}
		setSaving(true);
		try {
			await adminApi.setTelemetry(enabled);
			setPending(false);
		} catch (e) {
			toast.error(e instanceof ApiError ? e.message : "Save failed");
		} finally {
			setSaving(false);
		}
	}

	if (!pending) {
		return null;
	}

	return (
		<aside
			aria-label="Usage statistics"
			className="fixed right-4 bottom-4 z-50 max-w-sm space-y-3 rounded-lg border border-border bg-card p-4 text-sm shadow-lg"
		>
			<p className="font-medium text-foreground">This instance sends anonymous usage stats</p>
			<p className="text-muted-foreground text-xs">
				Once a day: a random install ID, version, OS, CPU architecture, and whether this runs in
				Docker. Never your notes, users, or hostnames. We do not store your IP address. Turn it off
				here, under Administration, or with <code>ENGRAM_TELEMETRY=false</code>.
			</p>
			<p className="flex flex-wrap gap-2">
				<button
					type="button"
					disabled={saving}
					onClick={() => answer(true)}
					className="rounded-md bg-primary px-3 py-1.5 font-medium text-primary-foreground text-xs"
				>
					Got it
				</button>
				<button
					type="button"
					disabled={saving}
					onClick={() => answer(false)}
					className="rounded-md border border-border bg-background px-3 py-1.5 font-medium text-xs hover:bg-accent"
				>
					Turn off
				</button>
			</p>
		</aside>
	);
}

// Ask-once notice for the self-host install census (on by default). Split in two so SaaS (Clerk)
// never touches the admin endpoint, which only exists under local auth.
export default function TelemetryPrompt() {
	const config = useConfig();
	return config.authProvider === "local" ? <AdminTelemetryPrompt /> : null;
}
