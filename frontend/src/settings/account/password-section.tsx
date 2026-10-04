import { useReverification, useUser } from "@clerk/react";
import { isReverificationCancelledError } from "@clerk/react/errors";
import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { SettingsSectionCard } from "./section-card";

const inputClass =
	"mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring";

export function PasswordSection() {
	const { t } = useT();
	const { user, isLoaded } = useUser();
	const [current, setCurrent] = useState("");
	const [next, setNext] = useState("");
	const update = useReverification(
		(params: { newPassword: string; currentPassword?: string; signOutOfOtherSessions?: boolean }) =>
			user!.updatePassword(params),
	);

	if (!(isLoaded && user)) {
		return null;
	}
	const hasPassword = user.passwordEnabled;

	async function submit() {
		try {
			await update({
				...(hasPassword ? { currentPassword: current } : {}),
				newPassword: next,
				signOutOfOtherSessions: true,
			});
			setCurrent("");
			setNext("");
			toast.success(t("Password updated"));
		} catch (e) {
			if (isReverificationCancelledError(e)) {
				return;
			}
			toast.error(t("Could not update password"));
		}
	}

	return (
		<SettingsSectionCard title={t("Password")} description={t("Set or change your password.")}>
			<form
				onSubmit={(e) => {
					e.preventDefault();
					submit();
				}}
			>
				{Boolean(hasPassword) && (
					<label className="block font-medium text-foreground text-sm">
						{t("Current password")}
						<input
							className={inputClass}
							type="password"
							value={current}
							onChange={(e) => setCurrent(e.target.value)}
						/>
					</label>
				)}
				<label className="mt-4 block font-medium text-foreground text-sm">
					{t("New password")}
					<input
						className={inputClass}
						type="password"
						value={next}
						onChange={(e) => setNext(e.target.value)}
					/>
				</label>
				<p className="mt-1 text-muted-foreground text-xs">
					{t("Changing your password signs you out of all other sessions.")}
				</p>
				<Button className="mt-4" type="submit">
					{hasPassword ? t("Update password") : t("Set password")}
				</Button>
			</form>
		</SettingsSectionCard>
	);
}
