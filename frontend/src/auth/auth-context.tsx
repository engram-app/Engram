import { createContext } from "react";

export interface AuthAdapter {
	isLoaded: boolean;
	isSignedIn: boolean;
	user: { email: string; imageUrl?: string } | null;

	// `skipCache`: mint past the provider's cache, for a token the server just
	// refused. Providers without a cache ignore it.
	getToken(opts?: { skipCache?: boolean }): Promise<string | null>;

	login?(email: string, password: string): Promise<void>;
	register?(email: string, password: string, invite?: string): Promise<void>;
	logout(): Promise<void>;

	/** Clerk renders its own SignIn/SignUp/UserButton; local mode uses custom components */
	hasBuiltInUI: boolean;
}

export const AuthContext = createContext<AuthAdapter | null>(null);
