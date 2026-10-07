import { Monitor, Moon, Sun } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { msg } from "@/i18n/msg";
import type { ThemeChoice } from "@/theme/storage";
import { useTheme } from "@/theme/theme-provider";
import { SettingsSectionCard } from "./section-card";

const OPTIONS: ReadonlyArray<{ value: ThemeChoice; label: string; Icon: typeof Sun }> = [
	{ value: "light", label: msg("Light"), Icon: Sun },
	{ value: "dark", label: msg("Dark"), Icon: Moon },
	{ value: "system", label: msg("System"), Icon: Monitor },
];

export function AppearanceSection() {
	const { t } = useT();
	const { theme, setTheme } = useTheme();
	return (
		<SettingsSectionCard
			title={t("Appearance")}
			description={t("Choose how Engram looks on this device.")}
			centerAction
			headerAction={
				<fieldset className="flex flex-wrap gap-2">
					<legend className="sr-only">{t("Theme")}</legend>
					{OPTIONS.map(({ value, label, Icon }) => (
						<Button
							key={value}
							type="button"
							variant={theme === value ? "default" : "outline"}
							aria-pressed={theme === value}
							onClick={() => setTheme(value)}
						>
							<Icon data-icon="inline-start" />
							{t(label)}
						</Button>
					))}
				</fieldset>
			}
		/>
	);
}
