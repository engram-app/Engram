import { useEffect, useState } from "react";
import { toast } from "sonner";
import { ApiError } from "@/api/client";
import { useT } from "@/i18n/locale-provider";
import { msg } from "@/i18n/msg";
import { adminApi, type RegistrationMode } from "./api";

const MODES: { value: RegistrationMode; label: string; hint: string }[] = [
	{
		value: "invite_only",
		label: msg("Invite only"),
		hint: msg("New accounts need an invite link."),
	},
	{
		value: "open",
		label: msg("Open"),
		hint: msg("Anyone can create an account. Use with care."),
	},
	{
		value: "closed",
		label: msg("Closed"),
		hint: msg("No new accounts, even with a link."),
	},
];

export default function RegistrationTab() {
	const { t } = useT();
	const [mode, setMode] = useState<RegistrationMode | null>(null);
	const [saving, setSaving] = useState(false);

	useEffect(() => {
		adminApi
			.getRegistration()
			.then((r) => setMode(r.registration_mode))
			.catch((e: unknown) => {
				const message = e instanceof ApiError ? e.message : t("Failed to load setting");
				toast.error(message);
			});
	}, [t]);

	async function choose(next: RegistrationMode) {
		if (next === mode || saving) {
			return;
		}
		setSaving(true);
		try {
			await adminApi.setRegistration(next);
			setMode(next);
			toast.success(t("Registration mode: {mode}", { mode: next }));
		} catch (e) {
			const message = e instanceof ApiError ? e.message : t("Save failed");
			toast.error(message);
		} finally {
			setSaving(false);
		}
	}

	if (!mode) {
		return <p className="text-muted-foreground text-sm">{t("Loading…")}</p>;
	}

	return (
		<fieldset disabled={saving} className="space-y-2">
			<legend className="mb-2 font-medium text-foreground text-sm">
				{t("Who can create accounts")}
			</legend>
			{MODES.map((m) => (
				<label
					key={m.value}
					className="flex cursor-pointer items-start gap-3 rounded-md border border-border p-3 hover:bg-accent/40 has-[input:checked]:border-primary has-[input:checked]:bg-primary/5"
				>
					<input
						type="radio"
						name="registration-mode"
						value={m.value}
						checked={mode === m.value}
						onChange={() => choose(m.value)}
						className="mt-1"
					/>
					<span className="flex-1">
						<strong className="block font-medium text-foreground text-sm">{t(m.label)}</strong>
						<span className="text-muted-foreground text-xs">{t(m.hint)}</span>
					</span>
				</label>
			))}
		</fieldset>
	);
}
