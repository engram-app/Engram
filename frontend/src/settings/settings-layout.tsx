import * as DialogPrimitive from "@radix-ui/react-dialog";
import { Menu, X } from "lucide-react";
import { lazy, Suspense, useEffect, useState } from "react";
import { Link, useLocation, useNavigate } from "react-router";
import { Button } from "@/components/ui/button";
import { Dialog, DialogOverlay } from "@/components/ui/dialog";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
	Sheet,
	SheetContent,
	SheetDescription,
	SheetTitle,
	SheetTrigger,
} from "@/components/ui/sheet";
import { useMe } from "../api/queries";
import { useConfig } from "../config-context";
import { buildSettingsSections, type SettingsSection } from "./sections";
import { type SettingsSectionKey, settingsHash } from "./settings-hash";

// Keep this in sync with the duration-200 class on DialogPrimitive.Content
// below — we hold the dialog mounted for one animation cycle after
// onOpenChange(false) so Radix's exit transition plays before we navigate.
const CLOSE_ANIMATION_MS = 200;

// These are the exact modules router.tsx lazy-loads today.
const AccountPage = lazy(() => import("./account-page"));
const AccountPageLocal = lazy(() => import("./account-page-local"));
const VaultsPage = lazy(() => import("./vaults-page"));
const ConnectionsPage = lazy(() => import("./connections-page"));
const BillingPage = lazy(() => import("../billing/billing-page"));
const AdminPanel = lazy(() => import("../features/admin/AdminPanel"));

function SectionBody({ section }: { section: SettingsSectionKey }) {
	const config = useConfig();
	switch (section) {
		case "vaults":
			return <VaultsPage />;
		case "connections":
			return <ConnectionsPage />;
		case "billing":
			return <BillingPage />;
		case "admin":
			return <AdminPanel />;
		default:
			return config.authProvider === "clerk" ? <AccountPage /> : <AccountPageLocal />;
	}
}

function SettingsNavList({
	sections,
	current,
	onNavigate,
}: {
	sections: SettingsSection[];
	current: SettingsSectionKey;
	onNavigate?: () => void;
}) {
	return (
		<ul className="space-y-1">
			{sections.map((s) => {
				const active = s.key === current;
				return (
					<li key={s.key}>
						{/* react-router's <Link>, not a plain <a>: a native anchor's
						fragment-only navigation fires `hashchange`, not `popstate`, and
						react-router's history only listens for `popstate` (a plain <a>
						would silently desync useLocation()). Link always resolves `to`
						against the current pathname (so href is e.g.
						"/work/note-1#settings/billing", not a bare hash), but it's
						routed through history.push, which react-router does see. */}
						<Link
							to={settingsHash(s.key)}
							onClick={onNavigate}
							aria-current={active ? "page" : undefined}
							className={`block rounded-md px-3 py-2 text-sm transition-colors ${
								active
									? "bg-primary/10 font-medium text-primary"
									: "text-muted-foreground hover:bg-accent hover:text-accent-foreground"
							}`}
						>
							{s.label}
						</Link>
					</li>
				);
			})}
		</ul>
	);
}

// Re-exported (rather than `export const` at the declaration site above) so
// this stays after all non-export statements, per biome's useExportsLast.
export { CLOSE_ANIMATION_MS };

export default function SettingsDialog({ section }: { section: SettingsSectionKey }) {
	const config = useConfig();
	const { data: me } = useMe();
	const isAdmin = me?.role === "admin";
	const sections = buildSettingsSections(config.authProvider, config.billingEnabled, isAdmin);
	const [navOpen, setNavOpen] = useState(false);
	const [open, setOpen] = useState(true);
	const navigate = useNavigate();
	const location = useLocation();

	// A hash can name a section this build does not have (`#settings/billing` on
	// self-host, `#settings/admin` as a non-admin). Fall back rather than render
	// an empty dialog body.
	const current = sections.some((s) => s.key === section) ? section : "account";

	// Close = strip the hash. Deferred by CLOSE_ANIMATION_MS so the Radix exit
	// transition plays. This replaces the old `navigate("/")`, which threw away
	// whatever page the user opened settings from.
	useEffect(() => {
		if (open) {
			return;
		}
		const t = setTimeout(
			() => navigate({ pathname: location.pathname, search: location.search, hash: "" }),
			CLOSE_ANIMATION_MS,
		);
		return () => clearTimeout(t);
	}, [open, navigate, location.pathname, location.search]);

	return (
		<Dialog open={open} onOpenChange={setOpen}>
			<DialogPrimitive.Portal>
				<DialogOverlay className="bg-background/20 supports-backdrop-filter:backdrop-blur-sm" />
				<DialogPrimitive.Content
					aria-describedby={undefined}
					className="data-open:fade-in-0 data-open:zoom-in-95 data-closed:fade-out-0 data-closed:zoom-out-95 fixed top-1/2 left-1/2 z-50 flex h-[88vh] w-[min(96vw,1100px)] max-w-none -translate-x-1/2 -translate-y-1/2 flex-col overflow-hidden rounded-xl border border-border bg-card shadow-xl duration-200 data-closed:animate-out data-open:animate-in"
				>
					<DialogPrimitive.Title className="sr-only">Settings</DialogPrimitive.Title>
					<DialogPrimitive.Close asChild>
						<Button
							variant="ghost"
							size="icon-sm"
							aria-label="Close settings"
							title="Close settings"
							className="absolute top-2 right-2 z-30 text-muted-foreground hover:text-foreground"
						>
							<X className="h-4 w-4" />
						</Button>
					</DialogPrimitive.Close>
					{/* Mobile: section switcher row */}
					<div className="flex items-center gap-2 border-border border-b px-3 py-1.5 md:hidden">
						<Sheet open={navOpen} onOpenChange={setNavOpen}>
							<SheetTrigger asChild>
								<Button
									variant="ghost"
									size="icon"
									aria-label="Open settings sections"
									className="size-9"
								>
									<Menu className="size-5" />
								</Button>
							</SheetTrigger>
							<SheetContent side="left" className="w-64 p-0">
								<SheetTitle className="border-border border-b px-4 py-3 font-semibold text-sm">
									Settings
								</SheetTitle>
								<SheetDescription className="sr-only">Settings sections</SheetDescription>
								<nav aria-label="Settings sections" className="p-3">
									<SettingsNavList
										sections={sections}
										current={current}
										onNavigate={() => setNavOpen(false)}
									/>
								</nav>
							</SheetContent>
						</Sheet>
						<span className="font-semibold text-foreground text-sm">Settings</span>
					</div>

					<div className="flex min-h-0 flex-1 flex-col md:flex-row">
						{/* Desktop: persistent side rail */}
						<nav
							aria-label="Settings sections"
							className="hidden h-full w-56 shrink-0 border-border border-r md:block"
						>
							<ScrollArea className="h-full">
								<div className="p-4">
									<h2 className="mb-3 px-3 font-semibold text-muted-foreground text-xs uppercase tracking-wide">
										Settings
									</h2>
									<SettingsNavList sections={sections} current={current} />
								</div>
							</ScrollArea>
						</nav>

						<ScrollArea className="min-h-0 min-w-0 flex-1">
							<div className="p-4 sm:p-6">
								<Suspense fallback={<p className="text-muted-foreground">Loading…</p>}>
									<SectionBody section={current} />
								</Suspense>
							</div>
						</ScrollArea>
					</div>
				</DialogPrimitive.Content>
			</DialogPrimitive.Portal>
		</Dialog>
	);
}
