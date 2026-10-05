import type { useT } from "@/i18n/locale-provider";
import type { Vars } from "@/i18n/translate";

// Types for non-component helpers that cannot call useT() themselves: the
// caller passes in the `t` / `tn` it got from the hook.
type Translate = (en: string, vars?: Vars) => string;
type Tn = ReturnType<typeof useT>["tn"];

export type { Tn, Translate };
