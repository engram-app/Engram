import { useId } from "react";
import { useT } from "@/i18n/locale-provider";

// Shown on the consent screen to someone who has never connected an app. The
// screen asks two real questions (which vaults, read only or not) with no
// context for why; this answers them before they are asked. A definition list,
// not a list: the vault picker below is the page's only list of rows.
export default function FirstTimeGuide({ client }: { client: string }) {
	const { t } = useT();
	const headingId = useId();

	return (
		<aside
			aria-labelledby={headingId}
			className="flex flex-col gap-2 rounded-md border border-border bg-muted/40 p-3 text-sm"
		>
			<h2 id={headingId} className="font-medium text-foreground">
				{t("How this works")}
			</h2>
			<dl className="flex flex-col gap-2">
				<dt className="font-medium text-foreground">{t("What {client} gets", { client })}</dt>
				<dd className="text-muted-foreground">
					{t("It can search and read your notes, and add or edit them if you allow it.")}
				</dd>
				<dt className="font-medium text-foreground">{t("What you choose here")}</dt>
				<dd className="text-muted-foreground">
					{t("You choose which vaults {client} can reach, and whether it is read only.", {
						client,
					})}
				</dd>
				<dt className="font-medium text-foreground">{t("After you approve")}</dt>
				<dd className="text-muted-foreground">
					{t("You return to {client}, and your vault opens in a new tab.", { client })}
				</dd>
			</dl>
			<p className="text-muted-foreground text-xs">
				{t("Change or revoke access anytime in Settings > Connections.")}
			</p>
		</aside>
	);
}
