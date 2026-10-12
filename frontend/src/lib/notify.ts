// The only way to raise a toast: sonner's own API takes any string, so raw
// English could reach the user. notify() takes UIText (from t/tn/untranslated)
// or an element. Biome's noRestrictedImports keeps `toast` out of other files.
import type { ReactElement } from "react";
import { type ExternalToast, toast } from "sonner";
import type { UIText } from "../i18n/ui-text";

type Message = UIText | ReactElement;
type Options = Omit<ExternalToast, "description"> & { description?: Message };
type Notify = ((message: Message, options?: Options) => void) & {
	error: (message: Message, options?: Options) => void;
	success: (message: Message, options?: Options) => void;
	info: (message: Message, options?: Options) => void;
};

// Looks `toast` up on each call, so a test's vi.mock("sonner") still applies.
const notify: Notify = Object.assign(
	(message: Message, options?: Options) => {
		toast(message, options);
	},
	{
		error: (message: Message, options?: Options) => {
			toast.error(message, options);
		},
		success: (message: Message, options?: Options) => {
			toast.success(message, options);
		},
		info: (message: Message, options?: Options) => {
			toast.info(message, options);
		},
	},
);

export { notify };
