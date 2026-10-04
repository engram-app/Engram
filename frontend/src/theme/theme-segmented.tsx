import { useT } from "@/i18n/locale-provider";
import { msg } from "@/i18n/msg";
import type { ThemeChoice } from "./storage";
import { useTheme } from "./theme-provider";

const OPTIONS: ReadonlyArray<{ value: ThemeChoice; label: string }> = [
	{ value: "light", label: msg("Light") },
	{ value: "dark", label: msg("Dark") },
	{ value: "system", label: msg("System") },
];

export default function ThemeSegmented() {
	const { theme, setTheme } = useTheme();
	const { t } = useT();
	return (
		<fieldset className="inline-flex rounded-md border border-gray-300 bg-white p-0.5 dark:border-gray-700 dark:bg-gray-900">
			<legend className="sr-only">{t("Theme")}</legend>
			{OPTIONS.map((opt) => {
				const active = theme === opt.value;
				return (
					<button
						key={opt.value}
						type="button"
						onClick={() => setTheme(opt.value)}
						aria-pressed={active}
						data-theme-option={opt.value}
						className={
							active
								? "rounded bg-blue-600 px-3 py-1 font-medium text-sm text-white dark:bg-blue-500"
								: "rounded px-3 py-1 text-gray-700 text-sm hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"
						}
					>
						{t(opt.label)}
					</button>
				);
			})}
		</fieldset>
	);
}
