import { FolderTree, Search, Settings } from "lucide-react";
import { NavLink, useLocation, useNavigate } from "react-router";
import { type RailView, useRailView } from "./rail-view-context";
import UserMenu from "./user-menu";

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
	const onSettings = location.pathname.startsWith("/settings");
	const active = view === id && !onSettings;
	const onClick = () => {
		setView(id);
		if (onSettings) {
			navigate("/");
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
			className={`flex h-8 w-8 items-center justify-center rounded-md transition-colors ${
				active
					? "bg-primary/15 text-primary hover:bg-primary/25"
					: "text-muted-foreground hover:bg-primary/10 hover:text-primary"
			}`}
		>
			<Icon className="h-5 w-5" />
		</button>
	);
}

export default function Rail() {
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
			<div className="flex-1" />
			<NavLink
				to="/settings"
				aria-label="Settings"
				title="Settings"
				className={({ isActive }) =>
					`flex h-8 w-8 items-center justify-center rounded-md transition-colors ${
						isActive
							? "bg-primary/15 text-primary hover:bg-primary/25"
							: "text-muted-foreground hover:bg-primary/10 hover:text-primary"
					}`
				}
			>
				<Settings className="h-5 w-5" />
			</NavLink>
			<UserMenu />
		</nav>
	);
}
