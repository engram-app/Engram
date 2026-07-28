import { FolderTree, Search, Settings } from "lucide-react";
import { Link, NavLink, useLocation, useNavigate } from "react-router";
import { isSettingsHash, settingsHash } from "../settings/settings-hash";
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

function ViewButton({
	id,
	label,
	dataTour,
	Icon,
}: {
	id: RailView;
	label: string;
	dataTour?: string;
	Icon: typeof Search;
}) {
	const { view, setView } = useRailView();
	const location = useLocation();
	const navigate = useNavigate();
	const onSettings = isSettingsHash(location.hash);
	const active = view === id && !onSettings;
	const onClick = () => {
		setView(id);
		if (onSettings) {
			// Strip the settings hash, stay on the page underneath.
			navigate({ pathname: location.pathname, search: location.search, hash: "" });
		}
	};
	return (
		<button
			type="button"
			aria-label={label}
			aria-current={active ? "page" : undefined}
			data-tour={dataTour}
			title={label}
			onClick={onClick}
			className={railButtonClass(active)}
		>
			<Icon className="h-5 w-5" />
		</button>
	);
}

function ToolButton({ tool }: { tool: RightToolDescriptor }) {
	const { resolvedId, toggleActive, isAvailable } = useRightTools();
	const available = isAvailable(tool.id);
	const active = resolvedId === tool.id;
	return (
		<button
			type="button"
			aria-label={tool.label}
			// aria-pressed, not aria-current: these toggle a panel open and shut,
			// they do not mark the current location the way the view buttons do.
			aria-pressed={active}
			disabled={!available}
			title={available ? tool.label : `${tool.label} (open a note first)`}
			onClick={() => toggleActive(tool.id)}
			className={`${railButtonClass(active)} disabled:pointer-events-none disabled:opacity-40`}
		>
			<tool.Icon className="h-5 w-5" />
		</button>
	);
}

export default function Rail() {
	const location = useLocation();
	const onSettings = isSettingsHash(location.hash);
	return (
		<nav
			aria-label="App navigation"
			className="flex h-full w-12 shrink-0 flex-col items-center gap-2 border-border border-r bg-card pt-3 pb-4"
		>
			<NavLink
				to="/"
				aria-label="Engram home"
				className="mb-3 flex h-10 w-10 items-center justify-center rounded-md"
			>
				<img src="/engram-mark.svg" alt="" className="size-8" />
			</NavLink>

			<ViewButton id="files" label="Files" Icon={FolderTree} />
			<ViewButton id="search" label="Search" dataTour="search" Icon={Search} />

			<hr className="my-1 w-6 border-border border-t" />

			{RIGHT_TOOLS.map((tool) => (
				<ToolButton key={tool.id} tool={tool} />
			))}

			<div className="flex-1" />
			<Link
				to={settingsHash("account")}
				aria-label="Settings"
				title="Settings"
				aria-current={onSettings ? "page" : undefined}
				className={railButtonClass(onSettings)}
			>
				<Settings className="h-5 w-5" />
			</Link>
			<UserMenu />
		</nav>
	);
}
