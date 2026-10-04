import { Link } from "react-router";
import { Button } from "@/components/ui/button";
import { heading } from "@/lib/ui-classes";
import { useT } from "./i18n/locale-provider";
import AuthPanel from "./layout/auth-panel";
import AuthShell from "./layout/auth-shell";
import { ROUTES } from "./routes";

export default function NotFoundPage() {
	const { t } = useT();
	return (
		<AuthShell>
			<AuthPanel className="flex flex-col items-center gap-4 text-center">
				<p className="bg-gradient-to-r from-brand-purple to-primary bg-clip-text font-extrabold text-7xl text-transparent leading-none tracking-tight sm:text-8xl">
					404
				</p>
				<h1 className={heading}>{t("Page not found")}</h1>
				<p className="max-w-md text-muted-foreground text-sm">
					{t(
						"We couldn't find what you're looking for. The link may be broken or the page may have moved.",
					)}
				</p>
				<Button asChild className="mt-2">
					<Link to={ROUTES.HOME}>{t("Back to home")}</Link>
				</Button>
			</AuthPanel>
		</AuthShell>
	);
}
