import { useT } from "@/i18n/locale-provider";

export default function LoadingScreen() {
	const { t } = useT();
	return (
		<main
			role="status"
			aria-label={t("Loading")}
			className="flex h-screen flex-col items-center justify-center gap-3 bg-background text-foreground"
		>
			<span
				aria-hidden="true"
				className="size-6 animate-spin rounded-full border-2 border-border border-t-primary"
			/>
			<p className="text-muted-foreground text-sm">{t("Loading…")}</p>
		</main>
	);
}
