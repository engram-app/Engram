import { Socket } from "phoenix";
import { useEffect, useLayoutEffect, useRef } from "react";
import { useLocation, useNavigate } from "react-router";
import { getWsBase, joinWsUrl } from "../api/base";
import { useMe } from "../api/queries";
import { useAuthAdapter } from "../auth/use-auth-adapter";
import { useStableT } from "../i18n/locale-provider";
import { notify } from "../lib/notify";
import { ROUTES, VAULT_PREFIX } from "../routes";

interface ConnectionCreatedPayload {
	client_name: string | null;
	kind: string;
}

// How long the notice waits before taking the user into their vault.
const ADVANCE_MS = 3000;

/**
 * The consent tab hands straight back to the client (a second tab broke the
 * handoff on mobile), so the user reaches their vault from here instead: on
 * the server's `connection_created` (sent once, on code exchange), any open
 * tab says "{client} is connected" and moves into the vault after a few
 * seconds. "Continue" goes at once, "Stay here" or closing the toast cancels.
 * A tab already in the vault is only told, never moved off its note.
 *
 * Same channel and socket pattern as `useSubscriptionActivatedEvents`.
 */
export function ConnectionCreatedNotice() {
	const userId = useMe().data?.id;
	const { getToken } = useAuthAdapter();
	const { t } = useStableT();
	const navigate = useNavigate();
	const { pathname } = useLocation();
	// Read at event time through a ref: navigating must not reopen the socket.
	const inVault = useRef(false);
	useLayoutEffect(() => {
		inVault.current = pathname.startsWith(`${VAULT_PREFIX}/`);
	}, [pathname]);

	useEffect(() => {
		if (!userId) {
			return;
		}

		let socket: Socket | null = null;
		let cancelled = false;

		const announce = ({ client_name }: ConnectionCreatedPayload) => {
			const message = client_name
				? t("{client} is connected", { client: client_name })
				: t("Your AI tool is connected");
			if (inVault.current) {
				notify.success(message);
				return;
			}
			const go = () => navigate(ROUTES.HOME);
			// Auto-close only fires when the timer runs out, not on a dismiss, so
			// "Stay here" and the close button both cancel the advance.
			notify.success(message, {
				duration: ADVANCE_MS,
				action: { label: t("Continue to your vault"), onClick: go },
				cancel: {
					label: t("Stay here"),
					onClick: () => {
						// Dismissing is the whole job: a dismiss never auto-closes.
					},
				},
				onAutoClose: go,
			});
		};

		async function connect() {
			const token = await getToken();
			if (cancelled || !token) {
				return;
			}
			socket = new Socket(joinWsUrl(getWsBase(), "/socket"), { params: { token } });
			socket.connect();
			const channel = socket.channel(`user:${userId}`);
			channel.on("connection_created", announce);
			channel.join().receive("error", (resp) => {
				console.error("user channel join failed (connection notice)", resp);
			});
		}

		connect().catch((err) => {
			console.error("user channel connect failed (connection notice)", err);
		});

		return () => {
			cancelled = true;
			socket?.disconnect();
		};
	}, [userId, getToken, t, navigate]);

	return null;
}
