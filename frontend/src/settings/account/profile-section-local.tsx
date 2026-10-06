import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useT } from "@/i18n/locale-provider";
import { useMe, useUpdateProfile } from "../../api/queries";
import { SettingsSectionCard } from "./section-card";

export function ProfileSectionLocal() {
	const { t } = useT();
	const { data } = useMe();
	const update = useUpdateProfile();
	const current = data?.display_name ?? "";
	const [value, setValue] = useState(current);
	// Re-seed the draft only when the server value itself changes, comparing
	// against the last one we saw. The effect this replaces ran on every
	// `current` identity change, so a refetch could overwrite an in-flight edit.
	const [seeded, setSeeded] = useState(current);
	if (seeded !== current) {
		setSeeded(current);
		setValue(current);
	}

	const dirty = value.trim() !== (current ?? "").trim();

	async function onSubmit(e: React.FormEvent) {
		e.preventDefault();
		try {
			await update.mutateAsync({ display_name: value.trim() === "" ? null : value.trim() });
			toast.success(t("Profile updated"));
		} catch (err) {
			toast.error(err instanceof Error ? err.message : t("Could not update profile"));
		}
	}

	return (
		<SettingsSectionCard title={t("Profile")} description={t("How your name appears in the app.")}>
			<form onSubmit={onSubmit} className="flex flex-wrap items-end gap-3">
				<label
					className="block min-w-48 flex-1 font-medium text-foreground text-sm"
					htmlFor="display-name"
				>
					{t("Display name")}
					<Input
						id="display-name"
						className="mt-1 block"
						value={value}
						maxLength={80}
						onChange={(e) => setValue(e.target.value)}
						placeholder={t("Leave blank to use your email")}
					/>
				</label>
				<Button type="submit" size="sm" disabled={!dirty || update.isPending}>
					{update.isPending ? t("Saving…") : t("Save")}
				</Button>
			</form>
		</SettingsSectionCard>
	);
}
