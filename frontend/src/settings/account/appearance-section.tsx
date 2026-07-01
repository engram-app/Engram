import { Monitor, Moon, Sun } from "lucide-react";
import { Button } from "@/components/ui/button";
import type { ThemeChoice } from "@/theme/storage";
import { useTheme } from "@/theme/theme-provider";
import { SettingsSectionCard } from "./section-card";

const OPTIONS: ReadonlyArray<{ value: ThemeChoice; label: string; Icon: typeof Sun }> = [
	{ value: "light", label: "Light", Icon: Sun },
	{ value: "dark", label: "Dark", Icon: Moon },
	{ value: "system", label: "System", Icon: Monitor },
];

export function AppearanceSection() {
	const { theme, setTheme } = useTheme();
	return (
		<SettingsSectionCard title="Appearance" description="Choose how Engram looks on this device.">
			<fieldset className="flex flex-wrap gap-2">
				<legend className="sr-only">Theme</legend>
				{OPTIONS.map(({ value, label, Icon }) => (
					<Button
						key={value}
						type="button"
						variant={theme === value ? "default" : "outline"}
						size="sm"
						className="gap-2"
						aria-pressed={theme === value}
						onClick={() => setTheme(value)}
					>
						<Icon className="size-4" />
						{label}
					</Button>
				))}
			</fieldset>
		</SettingsSectionCard>
	);
}
