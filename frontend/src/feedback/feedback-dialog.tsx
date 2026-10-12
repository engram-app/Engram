import { Loader2 } from "lucide-react";
import { RadioGroup as RadioGroupPrimitive } from "radix-ui";
import { useRef, useState } from "react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
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
import { FEEDBACK_CATEGORIES, MOOD_FACES } from "./options";

const chip =
	"inline-flex cursor-pointer items-center gap-1.5 rounded-full border px-2.5 py-1 text-sm transition-colors outline-none focus-visible:ring-3 focus-visible:ring-ring/50 border-border hover:border-primary/50 data-[state=checked]:border-primary data-[state=checked]:bg-primary/10";

interface FeedbackDialogProps {
	open: boolean;
	onOpenChange: (open: boolean) => void;
}

// Where the user was, coarsely. The vault slug, the note path and a heading
// anchor are all user data, so only the settings section survives verbatim.
export function feedbackArea(pathname: string, hash: string): string {
	const section = hash.replace(/^#/u, "").split("/").slice(0, 2).join("/");
	if (section.startsWith("settings")) {
		return section;
	}
	const vault = /^\/v\/[^/]+(?<rest>\/.+)?$/u.exec(pathname);
	if (vault) {
		return vault.groups?.rest ? "note" : "vault";
	}
	return pathname.split("/")[1] || "home";
}

export function FeedbackDialog({ open, onOpenChange }: FeedbackDialogProps) {
	const { t } = useT();
	const submit = useSubmitFeedback();
	const [message, setMessage] = useState("");
	const [category, setCategory] = useState("");
	const [mood, setMood] = useState("");
	const [contactOk, setContactOk] = useState(false);
	const textRef = useRef<HTMLTextAreaElement>(null);
	const trimmed = message.trim();

	async function send() {
		// Unlike the survey answers, the user is waiting on this one: surface
		// failure and keep their text rather than dropping it.
		try {
			await submit.mutateAsync({
				kind: "general",
				message: trimmed,
				...(category ? { category } : {}),
				...(mood ? { mood: Number(mood) } : {}),
				contact_ok: contactOk,
				source: "web",
				area: feedbackArea(window.location.pathname, window.location.hash),
			});
		} catch {
			return;
		}
		toast.success(t("Thanks, we read every message."));
		setMessage("");
		setCategory("");
		setMood("");
		setContactOk(false);
		onOpenChange(false);
	}

	return (
		<Dialog open={open} onOpenChange={onOpenChange}>
			<DialogContent
				className="max-w-2xl"
				// Start in the text box, not on the first category chip.
				onOpenAutoFocus={(e) => {
					e.preventDefault();
					textRef.current?.focus();
				}}
			>
				<DialogHeader>
					<DialogTitle>{t("Send feedback")}</DialogTitle>
					<DialogDescription>
						{t("What's working, what's frustrating, what do you wish Engram did?")}
					</DialogDescription>
				</DialogHeader>
				{/* One composer: kind on top, text in the middle, mood along the
				    bottom edge, so the form reads as a single message. */}
				<div className="rounded-lg border border-input transition-colors focus-within:border-ring focus-within:ring-3 focus-within:ring-ring/50 dark:bg-input/30">
					<RadioGroupPrimitive.Root
						value={category}
						onValueChange={setCategory}
						aria-label={t("What kind of feedback?")}
						className="flex flex-wrap gap-1.5 border-input border-b p-2"
					>
						{FEEDBACK_CATEGORIES.map((c) => (
							<RadioGroupPrimitive.Item key={c.slug} value={c.slug} className={chip}>
								<span aria-hidden>{c.emoji}</span>
								{t(c.label)}
							</RadioGroupPrimitive.Item>
						))}
					</RadioGroupPrimitive.Root>
					<Textarea
						ref={textRef}
						value={message}
						maxLength={2000}
						aria-label={t("Your feedback")}
						placeholder={t("Tell us anything")}
						onChange={(e) => setMessage(e.target.value)}
						className="min-h-48 resize-none rounded-none border-0 bg-transparent p-3 focus-visible:ring-0 dark:bg-transparent"
					/>
					<div className="flex items-center justify-between gap-3 border-input border-t px-3 py-1.5">
						<span id="feedback-mood" className="text-muted-foreground text-xs">
							{t("How do you feel about Engram?")}
						</span>
						<RadioGroupPrimitive.Root
							value={mood}
							onValueChange={setMood}
							aria-labelledby="feedback-mood"
							className="flex gap-0.5"
						>
							{MOOD_FACES.map((face, i) => {
								const label = t("{n} of 5", { n: i + 1 });
								return (
									<RadioGroupPrimitive.Item
										key={face}
										value={String(i + 1)}
										aria-label={label}
										title={label}
										className="cursor-pointer rounded-md p-1 text-lg opacity-40 outline-none grayscale transition hover:opacity-100 hover:grayscale-0 focus-visible:ring-3 focus-visible:ring-ring/50 data-[state=checked]:scale-125 data-[state=checked]:opacity-100 data-[state=checked]:grayscale-0"
									>
										{face}
									</RadioGroupPrimitive.Item>
								);
							})}
						</RadioGroupPrimitive.Root>
					</div>
				</div>
				{submit.isError ? (
					<p role="alert" className="text-destructive text-sm">
						{t("Couldn't send your feedback, please try again.")}
					</p>
				) : null}
				<DialogFooter className="items-center sm:justify-between">
					<label className="flex items-center gap-2 text-muted-foreground text-sm">
						<Checkbox
							checked={contactOk}
							onCheckedChange={(v) => setContactOk(v === true)}
							aria-label={t("It's OK to email me about this")}
						/>
						{t("It's OK to email me about this")}
					</label>
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
