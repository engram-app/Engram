import { createContext, type ReactNode, useCallback, useContext, useMemo, useState } from "react";
import { resetActiveVaultToStored } from "../../api/active-vault";

interface DemoVaultData {
	vault: DemoVault;
	folders: DemoFolder[];
	notes: DemoNote[];
}

interface DemoVaultCtx {
	active: boolean;
	vault: DemoVault | null;
	folders: DemoFolder[];
	notes: DemoNote[];
	activate: () => Promise<void>;
	deactivate: () => void;
}

const Ctx = createContext<DemoVaultCtx | null>(null);

export interface DemoNote {
	id: string;
	folder_id: string;
	path: string;
	title: string;
	content: string;
}

export interface DemoFolder {
	id: string;
	name: string;
	path: string;
}

export interface DemoVault {
	id: string;
	name: string;
}

export function DemoVaultProvider({ children }: { children: ReactNode }) {
	const [data, setData] = useState<DemoVaultData | null>(null);

	const activate = useCallback(async () => {
		// Static SPA asset, not an API call — served from same origin on both selfhost and CF Pages.
		const res = await fetch("/demo-vault.json");
		if (!res.ok) {
			throw new Error("demo fixture missing");
		}
		const json = (await res.json()) as DemoVaultData;
		setData(json);
	}, []);

	const deactivate = useCallback(() => {
		setData(null);
		// A demo vault may be the live selection; restore the real one so the app
		// stops sending `demo-vault-*` to the API once the tour ends.
		resetActiveVaultToStored();
	}, []);

	const value = useMemo<DemoVaultCtx>(
		() => ({
			active: data !== null,
			vault: data?.vault ?? null,
			folders: data?.folders ?? [],
			notes: data?.notes ?? [],
			activate,
			deactivate,
		}),
		[data, activate, deactivate],
	);

	return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useDemoVault(): DemoVaultCtx {
	const v = useContext(Ctx);
	if (!v) {
		throw new Error("useDemoVault must be used inside DemoVaultProvider");
	}
	return v;
}

// Optional version that returns null instead of throwing — for hooks that may
// be called outside the provider tree (e.g., settings pages).
export function useDemoVaultOptional(): DemoVaultCtx | null {
	return useContext(Ctx);
}
