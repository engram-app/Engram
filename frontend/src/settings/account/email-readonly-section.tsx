import { Copy } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import { copyToClipboard } from "@/lib/clipboard";
import { useMe } from "../../api/queries";
import { SettingsSectionCard } from "./section-card";

export function EmailReadonlySection() {
	const { data } = useMe();
	const email = data?.email ?? "";

	async function copy() {
		// This one already degraded politely — its try/catch caught the missing
		// namespace — but it could never actually copy on a non-secure origin.
		// The shared helper adds the execCommand fallback that can.
		if (await copyToClipboard(email)) {
			toast.success("Email copied");
		} else {
			toast.error("Could not copy");
		}
	}

	return (
		<SettingsSectionCard title="Email" description="To change your email, contact your admin.">
			<div className="flex items-center justify-between gap-3 rounded-md border border-border bg-muted/40 px-3 py-2">
				<span className="truncate font-mono text-sm">{email}</span>
				<Button
					type="button"
					variant="ghost"
					size="sm"
					aria-label="Copy email"
					onClick={copy}
					className="gap-1"
				>
					<Copy className="size-4" /> Copy
				</Button>
			</div>
		</SettingsSectionCard>
	);
}
