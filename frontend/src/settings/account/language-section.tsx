import {
	Select,
	SelectContent,
	SelectItem,
	SelectTrigger,
	SelectValue,
} from "@/components/ui/select";
import { useT } from "@/i18n/locale-provider";
import { LOCALE_NAMES, LOCALES } from "@/i18n/locales";
import { isMember } from "@/lib/is-member";
import { SettingsSectionCard } from "./section-card";

export function LanguageSection() {
	const { t, locale, setLocale } = useT();
	return (
		<SettingsSectionCard
			title={t("Language")}
			description={t("Choose the language Engram uses on this device.")}
			centerAction
			headerAction={
				<Select
					value={locale}
					onValueChange={(value) => {
						if (isMember(LOCALES, value)) {
							setLocale(value);
						}
					}}
				>
					<SelectTrigger aria-label={t("Language")} className="w-full sm:w-56">
						<SelectValue />
					</SelectTrigger>
					<SelectContent>
						{LOCALES.map((code) => (
							<SelectItem key={code} value={code} lang={code}>
								{LOCALE_NAMES[code]}
							</SelectItem>
						))}
					</SelectContent>
				</Select>
			}
		/>
	);
}
