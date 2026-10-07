import { Monitor, Moon, Sun } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
	DropdownMenu,
	DropdownMenuContent,
	DropdownMenuItem,
	DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useT } from "@/i18n/locale-provider";
import { msg } from "@/i18n/msg";
import type { ThemeChoice } from "./storage";
import { useTheme } from "./theme-provider";

const OPTIONS: ReadonlyArray<{ value: ThemeChoice; label: string; Icon: typeof Sun }> = [
	{ value: "light", label: msg("Light"), Icon: Sun },
	{ value: "dark", label: msg("Dark"), Icon: Moon },
	{ value: "system", label: msg("System"), Icon: Monitor },
];

// Whole-sentence keys so each language orders the words itself (and English stays
// "Theme: system", lowercase, exactly as before the app was translated).
const THEME_LABELS: Record<ThemeChoice, string> = {
	light: msg("Theme: light"),
	dark: msg("Theme: dark"),
	system: msg("Theme: system"),
};

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
	const { t } = useT();
	const themeLabel = t(THEME_LABELS[theme]);

	return (
		<DropdownMenu>
			<DropdownMenuTrigger asChild>
				<Button
					variant="ghost"
					size="icon"
					aria-label={themeLabel}
					title={themeLabel}
					data-theme-choice={theme}
				>
					<ActiveIcon choice={theme} />
				</Button>
			</DropdownMenuTrigger>
			<DropdownMenuContent align="end" aria-label={t("Theme")}>
				{OPTIONS.map(({ value, label, Icon }) => (
					<DropdownMenuItem
						key={value}
						onSelect={() => setTheme(value)}
						data-theme-option={value}
						aria-current={theme === value ? "true" : undefined}
					>
						<Icon className="mr-2 size-4" />
						{t(label)}
					</DropdownMenuItem>
				))}
			</DropdownMenuContent>
		</DropdownMenu>
	);
}
