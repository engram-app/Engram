import { useClerk, useReverification, useUser } from "@clerk/react";
import { isReverificationCancelledError } from "@clerk/react/errors";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogClose,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
	DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { EMPTY_REASON, ReasonFields } from "@/feedback/reason-fields";
import { useT } from "@/i18n/locale-provider";
import { notify } from "@/lib/notify";
import { ROUTES } from "@/routes";
import { useSubmitFeedback } from "../../api/queries";
import { clearHttpCache } from "../../auth/clear-http-cache";
import { SettingsSectionCard } from "./section-card";

const CONFIRM = "delete my account";
// The answer is a nice-to-have: a hung request must not hold up the delete.
const FEEDBACK_TIMEOUT_MS = 3000;
export function DangerZoneSection() {
	const { t } = useT();
	const { user, isLoaded } = useUser();
	const clerk = useClerk();
	const [open, setOpen] = useState(false);
	const [phrase, setPhrase] = useState("");
	const [answer, setAnswer] = useState(EMPTY_REASON);
	const [deleting, setDeleting] = useState(false);
	const submitFeedback = useSubmitFeedback();
	const remove = useReverification(() => user!.delete());

	if (!(isLoaded && user)) {
		return null;
	}

	async function onDelete() {
		if (deleting) {
			return;
		}
		setDeleting(true);
		// Close first: Clerk's reverification modal can't take clicks under an
		// open modal dialog. The answers stay in state if they back out.
		setOpen(false);
		// Before the delete: once the account is gone there is no session to
		// send it with. The backend holds it until the erasure commits, so a
		// cancelled delete records nothing. A failed send never blocks the delete.
		const detail = answer.detail.trim();
		if (answer.reason || detail) {
			await Promise.race([
				submitFeedback
					.mutateAsync({
						kind: "delete_account",
						...(answer.reason ? { reason: answer.reason } : {}),
						...(detail ? { detail } : {}),
					})
					.catch(() => undefined),
				new Promise((resolve) => setTimeout(resolve, FEEDBACK_TIMEOUT_MS)),
			]);
		}
		try {
			await remove();
			clearHttpCache();
			await clerk.signOut({ redirectUrl: ROUTES.SIGN_IN });
		} catch (e) {
			setDeleting(false);
			if (isReverificationCancelledError(e)) {
				return;
			}
			notify.error(t("Could not delete account"));
		}
	}

	return (
		<SettingsSectionCard
			destructive
			title={t("Danger zone")}
			description={t(
				"Permanently delete your account and all associated data. This cannot be undone.",
			)}
			centerAction
			headerAction={
				<Dialog open={open} onOpenChange={setOpen}>
					<DialogTrigger asChild>
						<Button type="button" variant="destructive" disabled={deleting}>
							{t("Delete account")}
						</Button>
					</DialogTrigger>
					<DialogContent className="max-h-[90dvh] overflow-y-auto sm:max-w-2xl">
						<DialogHeader>
							<DialogTitle>{t("Delete your account?")}</DialogTitle>
							<DialogDescription>
								{t(
									"Permanently delete your account and all associated data. This cannot be undone.",
								)}
							</DialogDescription>
						</DialogHeader>
						<form
							className="space-y-4"
							onSubmit={(e) => {
								e.preventDefault();
								onDelete();
							}}
						>
							<ReasonFields
								legend={t("Why are you deleting your account?")}
								value={answer}
								onChange={setAnswer}
							/>
							<p className="text-muted-foreground text-xs">
								{t(
									"Your answer is kept after your account is deleted, without your name or email.",
								)}
							</p>
							<label className="block font-medium text-foreground text-sm">
								{t("Type \u0022{phrase}\u0022 to confirm", { phrase: CONFIRM })}
								<Input
									className="mt-1 block"
									value={phrase}
									onChange={(e) => setPhrase(e.target.value)}
								/>
							</label>
							<DialogFooter>
								<DialogClose asChild>
									<Button type="button" variant="outline">
										{t("Cancel")}
									</Button>
								</DialogClose>
								<Button
									type="submit"
									variant="destructive"
									disabled={phrase !== CONFIRM || deleting}
								>
									{t("Delete my account")}
								</Button>
							</DialogFooter>
						</form>
					</DialogContent>
				</Dialog>
			}
		/>
	);
}
