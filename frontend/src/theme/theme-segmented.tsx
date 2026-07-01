import type { ThemeChoice } from "./storage";
import { useTheme } from "./theme-provider";

const OPTIONS: ReadonlyArray<{ value: ThemeChoice; label: string }> = [
	{ value: "light", label: "Light" },
	{ value: "dark", label: "Dark" },
	{ value: "system", label: "System" },
];

export default function ThemeSegmented() {
	const { theme, setTheme } = useTheme();
	return (
		<fieldset className="inline-flex rounded-md border border-gray-300 bg-white p-0.5 dark:border-gray-700 dark:bg-gray-900">
			<legend className="sr-only">Theme</legend>
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
								? "rounded px-3 py-1 text-sm font-medium bg-blue-600 text-white dark:bg-blue-500"
								: "rounded px-3 py-1 text-sm text-gray-700 hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800"
						}
					>
						{opt.label}
					</button>
				);
			})}
		</fieldset>
	);
}
