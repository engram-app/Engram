import { useContext } from "react";
import { AuthContext, type AuthAdapter } from "./auth-context";

export function useAuthAdapter(): AuthAdapter {
	const adapter = useContext(AuthContext);
	if (!adapter) {
		throw new Error("useAuthAdapter must be used within an AuthProvider");
	}
	return adapter;
}
