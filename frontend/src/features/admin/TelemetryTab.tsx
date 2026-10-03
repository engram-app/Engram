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
				Help count Engram installs. Once a day this instance can send a random install ID, the
				version, OS, CPU architecture, and whether it runs in Docker. Never your notes, users, or IP
				address.
			</p>

			{Boolean(state.env_disabled) && (
				<p role="status" className="mt-3 rounded-md border border-border bg-muted p-3 text-sm">
					Disabled by this instance's environment (<code>DO_NOT_TRACK</code> or{" "}
					<code>ENGRAM_TELEMETRY</code>). Nothing is sent.
				</p>
			)}

			{state.telemetry_enabled === null ? (
				<p className="mt-4 flex gap-2">
					<button
						type="button"
						disabled={saving}
						onClick={() => answer(true)}
						className="rounded-md bg-primary px-3 py-1.5 font-medium text-primary-foreground text-xs"
					>
						Share anonymous stats
					</button>
					<button
						type="button"
						disabled={saving}
						onClick={() => answer(false)}
						className="rounded-md border border-border bg-background px-3 py-1.5 font-medium text-xs hover:bg-accent"
					>
						No thanks
					</button>
				</p>
			) : (
				<label className="mt-4 flex items-center gap-2 text-foreground text-sm">
					<input
						type="checkbox"
						checked={state.telemetry_enabled}
						disabled={saving || state.env_disabled}
						onChange={(e) => answer(e.target.checked)}
					/>
					Share anonymous install stats
				</label>
			)}

			<details className="mt-4 text-sm">
				<summary className="cursor-pointer text-muted-foreground">Exactly what is sent</summary>
				<pre className="mt-2 overflow-x-auto rounded bg-background p-3 text-xs">
					{JSON.stringify(state.payload, null, 2)}
				</pre>
			</details>
		</>
	);
}
