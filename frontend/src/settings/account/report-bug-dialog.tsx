import { useState } from "react";
import { toast } from "sonner";
import { useReportBug } from "@/api/queries";
import { Button } from "@/components/ui/button";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogFooter,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";

const inputClass =
	"w-full rounded-md border border-input bg-background px-3 py-2 text-sm ring-offset-background focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring";

export function ReportBugDialog({
	open,
	onOpenChange,
}: {
	open: boolean;
	onOpenChange: (open: boolean) => void;
}) {
	const [description, setDescription] = useState("");
	const report = useReportBug();

	function submit() {
		const text = description.trim();
		if (!text) {
			return;
		}
		report.mutate(
			{ description: text, surface: "web", app_version: import.meta.env.VITE_GIT_SHA ?? "dev" },
			{
				onSuccess: () => {
					toast.success("Report sent");
					setDescription("");
					onOpenChange(false);
				},
				onError: () => toast.error("Could not send report"),
			},
		);
	}

	return (
		<Dialog open={open} onOpenChange={onOpenChange}>
			<DialogContent>
				<DialogHeader>
					<DialogTitle>Report a bug</DialogTitle>
					<DialogDescription>
						Describe what went wrong. We attach your account and a time window so we can pull the
						logs.
					</DialogDescription>
				</DialogHeader>
				<form
					onSubmit={(e) => {
						e.preventDefault();
						submit();
					}}
				>
					<textarea
						className={inputClass}
						rows={6}
						placeholder="What happened?"
						value={description}
						onChange={(e) => setDescription(e.target.value)}
					/>
					<DialogFooter className="mt-4">
						<Button type="button" variant="ghost" size="sm" onClick={() => onOpenChange(false)}>
							Cancel
						</Button>
						<Button type="submit" size="sm" disabled={!description.trim() || report.isPending}>
							Send report
						</Button>
					</DialogFooter>
				</form>
			</DialogContent>
		</Dialog>
	);
}
