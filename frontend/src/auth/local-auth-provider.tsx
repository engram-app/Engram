import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { getApiBase, joinApiUrl } from "../api/base";
import { setTokenGetter } from "../api/client";
import { queryClient } from "../api/query-client";
import { type AuthAdapter, AuthContext } from "./auth-context";
import { useClearQueryCacheOnUserChange } from "./use-clear-query-cache-on-user-change";

function parseJwtPayload(token: string): Record<string, unknown> | null {
	try {
		const base64 = token.split(".")[1];
		if (!base64) {
			return null;
		}
		const json = atob(base64.replace(/-/gu, "+").replace(/_/gu, "/"));
		return JSON.parse(json);
	} catch {
		return null;
	}
}

export default function LocalAuthProvider({ children }: { children: React.ReactNode }) {
	const [accessToken, setAccessToken] = useState<string | null>(null);
	const [user, setUser] = useState<{ email: string } | null>(null);
	const [isLoaded, setIsLoaded] = useState(false);
	const refreshPromiseRef = useRef<Promise<string | null> | null>(null);

	const doRefresh = useCallback((): Promise<string | null> => {
		// Single in-flight refresh at a time. Two concurrent /api/auth/refresh
		// calls present the same cookie value; the second would land at the
		// backend with a token revoked microseconds ago. The backend's leeway
		// window catches that race, but client-side dedup is still the cheaper
		// first line of defense (avoids the round-trip + an extra DB rotate).
		if (refreshPromiseRef.current) {
			return refreshPromiseRef.current;
		}

		const promise = fetch(joinApiUrl(getApiBase(), "/api/auth/refresh"), {
			method: "POST",
			credentials: "include",
		})
			.then(async (res) => {
				if (res.ok) {
					const data = await res.json();
					const payload = parseJwtPayload(data.access_token);
					setAccessToken(data.access_token);
					if (payload?.email) {
						setUser({ email: payload.email as string });
					}
					return data.access_token as string;
				}
				setAccessToken(null);
				setUser(null);
				return null;
			})
			.catch((err) => {
				console.error("Refresh failed:", err);
				return null;
			})
			.finally(() => {
				refreshPromiseRef.current = null;
			});

		refreshPromiseRef.current = promise;
		return promise;
	}, []);

	// On mount, attempt a silent refresh to restore session from cookie.
	// Routes through doRefresh so it shares the refreshPromiseRef dedup with
	// any in-flight API call that simultaneously demands a token (e.g. an
	// immediate useOnboardingStatus query firing on app load).
	useEffect(() => {
		doRefresh().finally(() => setIsLoaded(true));
	}, [doRefresh]);

	const getToken = useCallback(async () => {
		if (!accessToken) {
			return null;
		}

		// Check if token is expired (with 60s buffer)
		const payload = parseJwtPayload(accessToken);
		if (payload && (payload.exp as number) * 1000 >= Date.now() + 60_000) {
			return accessToken;
		}

		return doRefresh();
	}, [accessToken, doRefresh]);

	useEffect(() => {
		setTokenGetter(getToken);
	}, [getToken]);

	useClearQueryCacheOnUserChange(queryClient, user?.email);

	const login = useCallback(async (email: string, password: string) => {
		const res = await fetch(joinApiUrl(getApiBase(), "/api/auth/login"), {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			credentials: "include",
			body: JSON.stringify({ email, password }),
		});

		if (!res.ok) {
			const body = await res.json().catch(() => ({}));
			throw new Error(body.error ?? "Login failed");
		}

		const data = await res.json();
		setAccessToken(data.access_token);
		setUser({ email: data.user.email });
	}, []);

	const register = useCallback(async (email: string, password: string, invite?: string) => {
		// Self-host registration may be gated by invite_only mode; if the user
		// arrived via `/signup?invite=…` we pass the token here so the backend
		// can atomically redeem it.
		const body = invite ? { email, password, invite } : { email, password };
		const res = await fetch(joinApiUrl(getApiBase(), "/api/auth/register"), {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			credentials: "include",
			body: JSON.stringify(body),
		});

		if (!res.ok) {
			const body = await res.json().catch(() => ({}));
			throw new Error(body.error ?? "Registration failed");
		}

		const data = await res.json();
		setAccessToken(data.access_token);
		setUser({ email: data.user.email });
	}, []);

	const logout = useCallback(async () => {
		await fetch(joinApiUrl(getApiBase(), "/api/auth/logout"), {
			method: "POST",
			credentials: "include",
		}).catch((err) => console.error("Logout request failed:", err));
		setAccessToken(null);
		setUser(null);
	}, []);

	const adapter: AuthAdapter = useMemo(
		() => ({
			isLoaded,
			isSignedIn: Boolean(accessToken),
			user,
			getToken,
			login,
			register,
			logout,
			hasBuiltInUI: false,
		}),
		[isLoaded, accessToken, user, getToken, login, register, logout],
	);

	return <AuthContext.Provider value={adapter}>{children}</AuthContext.Provider>;
}
