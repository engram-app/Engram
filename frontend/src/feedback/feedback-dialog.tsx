import { Loader2 } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";
import { Textarea } from "@/components/ui/textarea";
import { useT } from "@/i18n/locale-provider";
import { useSubmitFeedback } from "../api/queries";

interface FeedbackDialogProps {
	open: boolean;
	onOpenChange: (open: boolean) => void;
}

export function FeedbackDialog({ open, onOpenChange }: FeedbackDialogProps) {
	const { t } = useT();
	const submit = useSubmitFeedback();
	const [message, setMessage] = useState("");
	const trimmed = message.trim();

	async function send() {
		// Unlike the survey answers, the user is waiting on this one: surface
		// failure and keep their text rather than dropping it.
		try {
			await submit.mutateAsync({ kind: "general", message: trimmed });
		} catch {
			return;
		}
		toast.success(t("Thanks, we read every message."));
		setMessage("");
		onOpenChange(false);
	}

	return (
		<Dialog open={open} onOpenChange={onOpenChange}>
			<DialogContent>
				<DialogHeader>
					<DialogTitle>{t("Send feedback")}</DialogTitle>
					<DialogDescription>
						{t("What's working, what's frustrating, what do you wish Engram did?")}
					</DialogDescription>
				</DialogHeader>
				<Textarea
					value={message}
					maxLength={2000}
					rows={5}
					aria-label={t("Your feedback")}
					onChange={(e) => setMessage(e.target.value)}
				/>
				{submit.isError ? (
					<p role="alert" className="text-destructive text-sm">
						{t("Couldn't send your feedback, please try again.")}
					</p>
				) : null}
				<DialogFooter>
					<Button onClick={send} disabled={!trimmed || submit.isPending}>
						{Boolean(submit.isPending) && (
							<Loader2 data-icon="inline-start" aria-hidden className="animate-spin" />
						)}
						{t("Send")}
					</Button>
				</DialogFooter>
			</DialogContent>
		</Dialog>
	);
}
