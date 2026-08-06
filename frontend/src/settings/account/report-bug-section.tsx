import { useState } from "react";
import { Button } from "@/components/ui/button";
import { ReportBugDialog } from "./report-bug-dialog";
import { SettingsSectionCard } from "./section-card";

export function ReportBugSection() {
	const [open, setOpen] = useState(false);
	return (
		<SettingsSectionCard
			title="Report a bug"
			description="Something not working? Send us a report and we'll dig into the logs."
			headerAction={
				<Button size="sm" onClick={() => setOpen(true)}>
					Report a bug
				</Button>
			}
		>
			<ReportBugDialog open={open} onOpenChange={setOpen} />
		</SettingsSectionCard>
	);
}
