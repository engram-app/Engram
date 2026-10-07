import { useState } from "react";
import { useNavigate } from "react-router";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useT } from "@/i18n/locale-provider";
import { api } from "../../api/client";
import { useAuthAdapter } from "../../auth/use-auth-adapter";
import { ROUTES } from "../../routes";
import { SettingsSectionCard } from "./section-card";

export function PasswordSectionLocal() {
	const { t } = useT();
	const { logout } = useAuthAdapter();
	const navigate = useNavigate();
	const [oldPw, setOldPw] = useState("");
	const [newPw, setNewPw] = useState("");
	const [confirmPw, setConfirmPw] = useState("");
	const [error, setError] = useState<string | null>(null);
	const [submitting, setSubmitting] = useState(false);

	async function onSubmit(e: React.FormEvent) {
		e.preventDefault();
		setError(null);

		if (newPw !== confirmPw) {
			setError(t("Passwords do not match"));
			return;
		}
		if (newPw.length < 8) {
			setError(t("New password must be at least 8 characters"));
			return;
		}

		setSubmitting(true);
		try {
			await api.post("/auth/password/change", { old_password: oldPw, new_password: newPw });
			toast.success(t("Password changed — please sign in again"));
			await logout();
			navigate(ROUTES.SIGN_IN);
		} catch (err) {
			const msg = err instanceof Error ? err.message : t("Password change failed");
			setError(msg);
		} finally {
			setSubmitting(false);
		}
	}

	return (
		<SettingsSectionCard
			title={t("Password")}
			description={t("Changing your password signs you out on all devices.")}
		>
			<form onSubmit={onSubmit} className="space-y-3">
				<label className="block font-medium text-foreground text-sm">
					{t("Current password")}
					<Input
						className="mt-1 block"
						type="password"
						autoComplete="current-password"
						value={oldPw}
						onChange={(e) => setOldPw(e.target.value)}
						required
					/>
				</label>
				<label className="block font-medium text-foreground text-sm">
					{t("New password")}
					<Input
						className="mt-1 block"
						type="password"
						autoComplete="new-password"
						value={newPw}
						onChange={(e) => setNewPw(e.target.value)}
						required
					/>
				</label>
				<label className="block font-medium text-foreground text-sm">
					{t("Confirm new password")}
					<Input
						className="mt-1 block"
						type="password"
						autoComplete="new-password"
						value={confirmPw}
						onChange={(e) => setConfirmPw(e.target.value)}
						required
					/>
				</label>
				{Boolean(error) && <p className="text-destructive text-sm">{error}</p>}
				<Button type="submit" variant="outline" disabled={submitting}>
					{submitting ? t("Changing…") : t("Change password")}
				</Button>
			</form>
		</SettingsSectionCard>
	);
}
