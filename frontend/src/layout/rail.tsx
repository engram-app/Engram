import { FolderTree, Search, Settings } from "lucide-react";
import { Link, NavLink, useLocation, useNavigate } from "react-router";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { useT } from "@/i18n/locale-provider";
import { isSettingsHash, settingsTo } from "../settings/settings-hash";
import { type RailView, useRailView } from "./rail-view-context";
import { RIGHT_TOOLS, type RightToolDescriptor, useRightTools } from "./right-tools-context";
import UserMenu from "./user-menu";

// The rail holds two groups, split by a divider:
//   TOP    — which panel fills the LEFT sidebar (Files, Search). Mutually
//            exclusive: picking one replaces the other.
//   BOTTOM — which tool fills the RIGHT sidebar (Outline, Reference). Toggles,
//            and independent of the top group — opening the reference must
//            never cost you the file tree.
// Shared button chrome keeps it reading as one control surface.
function railButtonClass(active: boolean): string {
	return `flex h-8 w-8 items-center justify-center rounded-md transition-colors ${
		active
			? "bg-primary/15 text-primary hover:bg-primary/25"
			: "text-muted-foreground hover:bg-primary/10 hover:text-primary"
	}`;
}

// The shared Tooltip (themed, like the rest of the UI) instead of the browser's
// native `title` tooltip. It opens to the right: the rail is a narrow column on
// the left edge, so that is the only side with room.
function RailTip({ label, children }: { label: string; children: React.ReactNode }) {
	return (
		<Tooltip>
			<TooltipTrigger asChild>{children}</TooltipTrigger>
			<TooltipContent side="right">{label}</TooltipContent>
		</Tooltip>
	);
}

function ViewButton({ id, label, Icon }: { id: RailView; label: string; Icon: typeof Search }) {
	const { view, setView, sidebarOpen, setSidebarOpen } = useRailView();
	const location = useLocation();
	const navigate = useNavigate();
	const onSettings = isSettingsHash(location.hash);
	// A collapsed sidebar shows no view, so no button reads as active.
	const active = view === id && sidebarOpen && !onSettings;
	const onClick = () => {
		// The active view's button is also its close button, like the right-hand
		// tool buttons: clicking what is showing hides it.
		if (active) {
			setSidebarOpen(false);
			return;
		}
		setView(id);
		setSidebarOpen(true);
		if (onSettings) {
			// Strip the settings hash, stay on the page underneath.
			navigate({ pathname: location.pathname, search: location.search, hash: "" });
		}
	};
	return (
		<RailTip label={label}>
			<button
				type="button"
				aria-label={label}
				aria-current={active ? "page" : undefined}
				onClick={onClick}
				className={railButtonClass(active)}
			>
				<Icon className="size-5" />
			</button>
		</RailTip>
	);
}

function ToolButton({ tool }: { tool: RightToolDescriptor }) {
	const { t } = useT();
	const { resolvedId, toggleActive, isAvailable } = useRightTools();
	const available = isAvailable(tool.id);
	const active = resolvedId === tool.id;
	const button = (
		<button
			type="button"
			aria-label={t(tool.label)}
			// aria-pressed, not aria-current: these toggle a panel open and shut,
			// they do not mark the current location the way the view buttons do.
			aria-pressed={active}
			disabled={!available}
			onClick={() => toggleActive(tool.id)}
			className={`${railButtonClass(active)} disabled:pointer-events-none disabled:opacity-40`}
		>
			<tool.Icon className="size-5" />
		</button>
	);
	if (available) {
		return <RailTip label={t(tool.label)}>{button}</RailTip>;
	}
	// A disabled button receives no pointer events, so the tooltip hangs off a
	// focusable wrapper and still tells you why it is unavailable.
	return (
		<RailTip label={t("{label} (open a note first)", { label: t(tool.label) })}>
			<span tabIndex={0} className="inline-flex rounded-md">
				{button}
			</span>
		</RailTip>
	);
}

export default function Rail() {
	const { t } = useT();
	const location = useLocation();
	const onSettings = isSettingsHash(location.hash);
	return (
		<nav
			aria-label={t("App navigation")}
			className="flex h-full w-12 shrink-0 flex-col items-center gap-2 border-border border-r bg-card pt-3 pb-4"
		>
			<NavLink
				to="/"
				aria-label={t("Engram home")}
				className="mb-3 flex size-10 items-center justify-center rounded-md"
			>
				<img src="/engram-mark.svg" alt="" className="size-8" />
			</NavLink>

			<ViewButton id="files" label={t("Files")} Icon={FolderTree} />
			<ViewButton id="search" label={t("Search")} Icon={Search} />

			<hr className="my-1 w-6 border-border border-t" />

			{RIGHT_TOOLS.map((tool) => (
				<ToolButton key={tool.id} tool={tool} />
			))}

			<div className="flex-1" />
			<RailTip label={t("Settings")}>
				<Link
					to={settingsTo("account", location.search)}
					aria-label={t("Settings")}
					aria-current={onSettings ? "page" : undefined}
					className={railButtonClass(onSettings)}
				>
					<Settings className="size-5" />
				</Link>
			</RailTip>
			<UserMenu />
		</nav>
	);
}
