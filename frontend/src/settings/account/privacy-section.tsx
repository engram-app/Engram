import { Checkbox } from "@/components/ui/checkbox";
import { useT } from "@/i18n/locale-provider";
import { notify } from "@/lib/notify";
import { serverErrorMessage } from "@/lib/server-error";
import { useMe, useUpdateProfile } from "../../api/queries";
import { SettingsSectionCard } from "./section-card";

// SaaS only: self-host never loads PostHog, so the local account page omits it.
// Capture stops or resumes through the ["me"] cache: use-identify-user-on-auth-change
// reacts to the new analytics_opt_out.
export function PrivacySection() {
	const { t } = useT();
	const { data } = useMe();
	const update = useUpdateProfile();

	async function onChange(share: boolean) {
		try {
			await update.mutateAsync({ analytics_opt_out: !share });
		} catch (err) {
			notify.error(serverErrorMessage(err, t("Could not save your analytics choice"), t));
		}
	}

	return (
		<SettingsSectionCard
			title={t("Privacy")}
			description={t(
				"Usage analytics help us see which features get used. The content of your notes is never sent.",
			)}
		>
			<label className="flex items-center gap-2 text-sm">
				<Checkbox
					checked={data ? !data.analytics_opt_out : false}
					disabled={!data || update.isPending}
					onCheckedChange={(v) => onChange(v === true)}
				/>
				{t("Share usage analytics")}
			</label>
		</SettingsSectionCard>
	);
}
