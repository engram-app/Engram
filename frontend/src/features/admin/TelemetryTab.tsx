import { useEffect, useState } from "react";
import { toast } from "sonner";
import { ApiError } from "@/api/client";
import { adminApi, type TelemetryState } from "./api";

export default function TelemetryTab() {
	const [state, setState] = useState<TelemetryState | null>(null);
	const [saving, setSaving] = useState(false);

	useEffect(() => {
		adminApi
			.getTelemetry()
			.then(setState)
			.catch((e: unknown) => {
				toast.error(e instanceof ApiError ? e.message : "Failed to load setting");
			});
	}, []);

	async function answer(enabled: boolean) {
		if (saving) {
			return;
		}
		setSaving(true);
		try {
			setState(await adminApi.setTelemetry(enabled));
		} catch (e) {
			toast.error(e instanceof ApiError ? e.message : "Save failed");
		} finally {
			setSaving(false);
		}
	}

	if (!state) {
		return <p className="text-muted-foreground text-sm">Loading…</p>;
	}

	return (
		<>
			<p className="text-muted-foreground text-sm">
				On by default. Once a day this instance sends an anonymous usage ping so we can count
				installs and platforms: a random install ID, the version, OS, CPU architecture, and whether
				it runs in Docker. Never your notes, users, or hostnames. We do not store your IP address.
			</p>

			{Boolean(state.env_disabled) && (
				<p role="status" className="mt-3 rounded-md border border-border bg-muted p-3 text-sm">
					Disabled by this instance's environment (<code>ENGRAM_TELEMETRY=false</code>). Nothing is
					sent.
				</p>
			)}

			<label className="mt-4 flex items-center gap-2 text-foreground text-sm">
				<input
					type="checkbox"
					checked={state.telemetry_enabled !== false && !state.env_disabled}
					disabled={saving || state.env_disabled}
					onChange={(e) => answer(e.target.checked)}
				/>
				Send anonymous usage stats
			</label>

			<details className="mt-4 text-sm">
				<summary className="cursor-pointer text-muted-foreground">Exactly what is sent</summary>
				<pre className="mt-2 overflow-x-auto rounded bg-background p-3 text-xs">
					{JSON.stringify(state.payload, null, 2)}
				</pre>
			</details>
		</>
	);
}
