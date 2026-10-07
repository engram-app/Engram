import { LanguageSelect } from "@/i18n/language-select";
import { useT } from "@/i18n/locale-provider";
import { SettingsSectionCard } from "./section-card";

export function LanguageSection() {
	const { t } = useT();
	return (
		<SettingsSectionCard
			title={t("Language")}
			description={t("Choose the language Engram uses on this device.")}
			centerAction
			headerAction={<LanguageSelect className="w-full sm:w-56" />}
		/>
	);
}
