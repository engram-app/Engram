import { LanguagesIcon } from "lucide-react";
import { buttonVariants } from "@/components/ui/button";
import {
	Select,
	SelectContent,
	SelectItem,
	SelectTrigger,
	SelectValue,
} from "@/components/ui/select";
import { isMember } from "@/lib/is-member";
import { cn } from "@/lib/utils";
import { useT } from "./locale-provider";
import { LOCALE_NAMES, LOCALES } from "./locales";

interface LanguageSelectProps {
	className?: string;
	// Outline icon button (styled like Button) instead of showing the current
	// language name. For cramped chrome such as top bars.
	iconOnly?: boolean;
}

export function LanguageSelect({ className, iconOnly = false }: LanguageSelectProps) {
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
			<SelectTrigger
				aria-label={t("Language")}
				title={t("Language")}
				className={cn(
					iconOnly &&
						cn(
							buttonVariants({ variant: "outline", size: "icon" }),
							"[&>svg:last-child]:hidden [&_svg:not([class*='size-'])]:size-5",
						),
					className,
				)}
			>
				{iconOnly ? <LanguagesIcon /> : <SelectValue />}
			</SelectTrigger>
			{/* item-aligned positions the list over the selected value's text; an icon
			    trigger has none, so the list lands off-screen. */}
			<SelectContent position={iconOnly ? "popper" : "item-aligned"} align="end">
				{LOCALES.map((code) => (
					<SelectItem key={code} value={code} lang={code}>
						{LOCALE_NAMES[code]}
					</SelectItem>
				))}
			</SelectContent>
		</Select>
	);
}
