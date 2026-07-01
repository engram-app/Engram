import { Monitor, Moon, Sun } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
	DropdownMenu,
	DropdownMenuContent,
	DropdownMenuItem,
	DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import type { ThemeChoice } from "./storage";
import { useTheme } from "./theme-provider";

const OPTIONS: ReadonlyArray<{ value: ThemeChoice; label: string; Icon: typeof Sun }> = [
	{ value: "light", label: "Light", Icon: Sun },
	{ value: "dark", label: "Dark", Icon: Moon },
	{ value: "system", label: "System", Icon: Monitor },
];

function ActiveIcon({ choice }: { choice: ThemeChoice }) {
	if (choice === "light") {
		return <Sun />;
	}
	if (choice === "dark") {
		return <Moon />;
	}
	return <Monitor />;
}

export default function ThemeToggle() {
	const { theme, setTheme } = useTheme();

	return (
		<DropdownMenu>
			<DropdownMenuTrigger asChild>
				<Button
					variant="ghost"
					size="icon"
					aria-label={`Theme: ${theme}`}
					title={`Theme: ${theme}`}
					data-theme-choice={theme}
				>
					<ActiveIcon choice={theme} />
				</Button>
			</DropdownMenuTrigger>
			<DropdownMenuContent align="end" aria-label="Theme">
				{OPTIONS.map(({ value, label, Icon }) => (
					<DropdownMenuItem
						key={value}
						onSelect={() => setTheme(value)}
						data-theme-option={value}
						aria-current={theme === value ? "true" : undefined}
					>
						<Icon className="mr-2 size-4" />
						{label}
					</DropdownMenuItem>
				))}
			</DropdownMenuContent>
		</DropdownMenu>
	);
}
