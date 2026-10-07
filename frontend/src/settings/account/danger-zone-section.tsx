import { useClerk, useReverification, useUser } from "@clerk/react";
import { isReverificationCancelledError } from "@clerk/react/errors";
import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useT } from "@/i18n/locale-provider";
import { ROUTES } from "@/routes";

const CONFIRM = "delete my account";
export function DangerZoneSection() {
	const { t } = useT();
	const { user, isLoaded } = useUser();
	const clerk = useClerk();
	const [phrase, setPhrase] = useState("");
	const remove = useReverification(() => user!.delete());

	if (!(isLoaded && user)) {
		return null;
	}

	async function onDelete() {
		try {
			await remove();
			await clerk.signOut({ redirectUrl: ROUTES.SIGN_IN });
		} catch (e) {
			if (isReverificationCancelledError(e)) {
				return;
			}
			toast.error(t("Could not delete account"));
		}
	}

	return (
		<section className="rounded-lg border border-destructive/40 bg-destructive/5 p-4 sm:p-6">
			<header className="mb-4">
				<h2 className="font-semibold text-base text-destructive">{t("Danger zone")}</h2>
				<p className="mt-1 text-muted-foreground text-sm">
					{t("Permanently delete your account and all associated data. This cannot be undone.")}
				</p>
			</header>
			<form
				onSubmit={(e) => {
					e.preventDefault();
					onDelete();
				}}
			>
				<label className="block font-medium text-foreground text-sm">
					{t("Type \u0022{phrase}\u0022 to confirm", { phrase: CONFIRM })}
					<Input
						className="mt-1 block"
						value={phrase}
						onChange={(e) => setPhrase(e.target.value)}
					/>
				</label>
				<Button className="mt-4" type="submit" variant="destructive" disabled={phrase !== CONFIRM}>
					{t("Delete my account")}
				</Button>
			</form>
		</section>
	);
}
