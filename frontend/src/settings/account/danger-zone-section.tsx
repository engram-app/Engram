import { useClerk, useReverification, useUser } from "@clerk/react";
import { isReverificationCancelledError } from "@clerk/react/errors";
import { useState } from "react";
import { toast } from "sonner";
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
import { EMPTY_REASON, ReasonFields, reasonComplete } from "@/feedback/reason-fields";
import { useT } from "@/i18n/locale-provider";
import { ROUTES } from "@/routes";
import { useSubmitFeedback } from "../../api/queries";
import { SettingsSectionCard } from "./section-card";

const CONFIRM = "delete my account";
export function DangerZoneSection() {
	const { t } = useT();
	const { user, isLoaded } = useUser();
	const clerk = useClerk();
	const [open, setOpen] = useState(false);
	const [phrase, setPhrase] = useState("");
	const [answer, setAnswer] = useState(EMPTY_REASON);
	const submitFeedback = useSubmitFeedback();
	const remove = useReverification(() => user!.delete());

	if (!(isLoaded && user)) {
		return null;
	}

	async function onDelete() {
		if (!answer.reason) {
			return;
		}
		// Close first: Clerk's reverification modal can't take clicks under an
		// open modal dialog. The answers stay in state if they back out.
		setOpen(false);
		// Before the delete: once the account is gone there is no session to
		// send it with. A failed send must not block the delete.
		await submitFeedback
			.mutateAsync({
				kind: "delete_account",
				reason: answer.reason,
				detail: answer.detail.trim(),
			})
			.catch(() => undefined);
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
		<SettingsSectionCard
			title={t("Danger zone")}
			description={t(
				"Permanently delete your account and all associated data. This cannot be undone.",
			)}
			centerAction
			headerAction={
				<Dialog open={open} onOpenChange={setOpen}>
					<DialogTrigger asChild>
						<Button type="button" variant="destructive">
							{t("Delete account")}
						</Button>
					</DialogTrigger>
					<DialogContent>
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
									disabled={
										phrase !== CONFIRM || !reasonComplete(answer) || submitFeedback.isPending
									}
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
