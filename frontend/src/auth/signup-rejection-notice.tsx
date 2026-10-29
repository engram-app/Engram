import { useEffect, useState } from "react";
import { useT } from "@/i18n/locale-provider";
import { destructiveAlert } from "@/lib/ui-classes";
import { cn } from "@/lib/utils";
import { clearAccountConflict, hasAccountConflict } from "./signup-rejection";

// Shown on the sign-in page after the app signed out on a 403
// `account_conflict`. Shown once: the flag is cleared after it is read.
export default function SignupRejectionNotice() {
	const { t } = useT();
	const [rejected] = useState(hasAccountConflict);

	useEffect(clearAccountConflict, []);

	if (!rejected) {
		return null;
	}

	return (
		<div role="alert" className={cn(destructiveAlert, "mb-4 w-full max-w-sm")}>
			<p className="font-medium text-foreground">
				{t("An account with this email already exists")}
			</p>
			<p className="mt-1 text-muted-foreground">{t("Contact support to restore access.")}</p>
		</div>
	);
}
