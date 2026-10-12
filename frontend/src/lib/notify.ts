// The only way to raise a toast: sonner's own API takes any string, so raw
// English could reach the user. notify() takes UIText (from t/tn/untranslated)
// or an element. Biome's noRestrictedImports keeps `toast` out of other files.
import type { ReactElement } from "react";
import { type ExternalToast, toast } from "sonner";
import type { UIText } from "../i18n/ui-text";

type Message = UIText | ReactElement;
type Options = Omit<ExternalToast, "description"> & { description?: Message };
type Args = [message: Message, options?: Options];
type Notify = ((...args: Args) => void) & {
	error: (...args: Args) => void;
	success: (...args: Args) => void;
	info: (...args: Args) => void;
};

// Looks `toast` up on each call, so a test's vi.mock("sonner") still applies, and
// forwards exactly the arguments given, so `toast.error("x")` assertions still match.
const notify: Notify = Object.assign(
	(...args: Args) => {
		toast(...args);
	},
	{
		error: (...args: Args) => {
			toast.error(...args);
		},
		success: (...args: Args) => {
			toast.success(...args);
		},
		info: (...args: Args) => {
			toast.info(...args);
		},
	},
);

export { notify };
