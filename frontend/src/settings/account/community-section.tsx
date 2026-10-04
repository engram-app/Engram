import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { DiscordIcon } from "./discord-icon";
import { SettingsSectionCard } from "./section-card";

// Community Discord invite — support and issue reports from users and devs.
export const DISCORD_INVITE_URL = "https://discord.gg/NG9Vn9VcPS";

export function CommunitySection() {
	const { t } = useT();
	return (
		<SettingsSectionCard
			title={t("Community")}
			description={t("Get help, report issues, and talk to other Engram users.")}
		>
			<Button asChild variant="outline" size="sm" className="gap-2">
				<a href={DISCORD_INVITE_URL} target="_blank" rel="noopener noreferrer">
					<DiscordIcon />
					{t("Join our Discord")}
				</a>
			</Button>
		</SettingsSectionCard>
	);
}
