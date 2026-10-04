import { Facet } from "@codemirror/state";
import { translate, type Vars } from "@/i18n/translate";

type Translate = (en: string, vars?: Vars) => string;

const englishTranslate: Translate = (en, vars) => translate({}, en, vars);

// CodeMirror widgets, tooltips and gutter markers are built outside React, so
// they cannot call the hook. The editor host adds the active translate function
// as this facet's value, and widgets read it from the state they are built
// against. Without a provider the value is English, which is also what the
// editor unit tests see.
const translator = Facet.define<Translate, Translate>({
	combine: (values) => values[0] ?? englishTranslate,
});

export { englishTranslate, type Translate, translator };
