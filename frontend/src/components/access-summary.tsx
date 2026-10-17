import { Ban, Eye, type LucideIcon, Pencil } from "lucide-react";
import type { AccessLevel } from "@/components/access-level-select";
import { useT } from "@/i18n/locale-provider";
import type { UIText } from "@/i18n/ui-text";
import { cn } from "@/lib/utils";

interface Chip {
	key: string;
	name: UIText | string;
	// A policy (vaults created later, every vault), not one vault.
	policy?: boolean;
}

function Group({ icon: Icon, title, chips }: { icon: LucideIcon; title: UIText; chips: Chip[] }) {
	return (
		<li className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-2">
			<Icon aria-hidden className="mt-0.5 size-5 text-muted-foreground" />
			<h3 className="font-medium text-base text-foreground">{title}</h3>
			<ul className="col-start-2 flex flex-wrap gap-1.5">
				{chips.map((chip) => (
					<li
						key={chip.key}
						className={cn(
							"rounded-md px-2.5 py-1 text-foreground text-sm",
							chip.policy ? "border border-border border-dashed" : "bg-muted",
						)}
					>
						{chip.name}
					</li>
				))}
			</ul>
		</li>
	);
}

// What the connection will be able to do, grouped by level, from the levels it
// will be granted (already capped by Read only).
export function AccessSummary({
	vaults,
	perVault,
	readOnly,
	levelOf,
	later,
}: {
	vaults: { id: string; name: string }[];
	perVault: boolean;
	readOnly: boolean;
	levelOf: (id: string) => AccessLevel;
	later: AccessLevel;
}) {
	const { t } = useT();
	const everything: Chip = {
		key: "all",
		name: t("All vaults, including ones you create later"),
		policy: true,
	};
	// Every vault at one level reads as one chip, not the whole list.
	const chipsAt = (level: AccessLevel): Chip[] => {
		if (!perVault) {
			return level === (readOnly ? "read" : "write") ? [everything] : [];
		}
		const at = vaults.filter((v) => levelOf(v.id) === level);
		const laterHere = later === level;
		if (at.length > 1 && at.length === vaults.length) {
			return laterHere
				? [everything]
				: [{ key: "current", name: t("All current vaults"), policy: true }];
		}
		return [
			...at.map((v) => ({ key: v.id, name: v.name })),
			...(laterHere ? [{ key: "later", name: t("Vaults you create later"), policy: true }] : []),
		];
	};
	const groups = (
		[
			["write", Pencil, t("Can read and change notes")],
			["read", Eye, t("Can read notes")],
			["none", Ban, t("No access")],
		] as const
	)
		.map(([level, icon, title]) => ({ level, icon, title, chips: chipsAt(level) }))
		.filter((g) => g.chips.length > 0);

	return (
		<>
			<ul className="flex flex-col gap-4">
				{groups.map((g) => (
					<Group key={g.level} icon={g.icon} title={g.title} chips={g.chips} />
				))}
			</ul>
			{readOnly ? (
				<p className="text-muted-foreground text-sm">
					{t("Cannot change, create or delete notes")}
				</p>
			) : null}
		</>
	);
}
