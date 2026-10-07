import {
	Select,
	SelectContent,
	SelectItem,
	SelectTrigger,
	SelectValue,
} from "@/components/ui/select";
import { isMember } from "@/lib/is-member";
import { useT } from "./locale-provider";
import { LOCALE_NAMES, LOCALES } from "./locales";

export function LanguageSelect({ className }: { className?: string }) {
	const { t, locale, setLocale } = useT();
	return (
		<Select
			value={locale}
			onValueChange={(value) => {
				if (isMember(LOCALES, value)) {
					setLocale(value);
				}
			}}
		>
			<SelectTrigger aria-label={t("Language")} className={className}>
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
	);
}
