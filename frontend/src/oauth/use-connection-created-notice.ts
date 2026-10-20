import { useEffect } from "react";
import { onConnectionCreated } from "../api/channel";
import { useStableT } from "../i18n/locale-provider";
import { notify } from "../lib/notify";

/**
 * The consent tab hands straight back to the client (a second tab broke the
 * handoff on mobile), so an open vault tab says "{client} is connected" when
 * the server's `connection_created` arrives (a user's first connection of
 * that client).
 *
 * It rides the tab's one sync socket (`api/channel.ts`), which only exists in
 * the vault; AppLayout mounts this next to useChannel. The tab is already
 * where the user would go, so it only tells, never navigates. Tabs outside
 * the vault (consent, /link, checkout) hear nothing and are never moved; the
 * "you're connected" email carries the link.
 */
export function useConnectionCreatedNotice(): void {
	const { t } = useStableT();

	useEffect(
		() =>
			onConnectionCreated(({ client_name }) => {
				notify.success(
					client_name
						? t("{client} is connected", { client: client_name })
						: t("Your AI tool is connected"),
				);
			}),
		[t],
	);
}
