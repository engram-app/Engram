import { Button } from "@/components/ui/button";
import { DiscordIcon } from "./discord-icon";
import { SettingsSectionCard } from "./section-card";

// Community Discord invite — support and issue reports from users and devs.
const DISCORD_INVITE_URL = "https://discord.gg/NKWcU2mm7N";

export function CommunitySection() {
	return (
		<SettingsSectionCard
			title="Community"
			description="Get help, report issues, and talk to other Engram users."
		>
			<Button asChild variant="outline" size="sm" className="gap-2">
				<a href={DISCORD_INVITE_URL} target="_blank" rel="noopener noreferrer">
					<DiscordIcon />
					Join our Discord
				</a>
			</Button>
		</SettingsSectionCard>
	);
}
