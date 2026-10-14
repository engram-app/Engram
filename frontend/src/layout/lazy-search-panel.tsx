import { type ComponentProps, lazy, Suspense } from "react";
import type SearchPanelComponent from "./search-panel";

// Lazy: search pulls in @base-ui's combobox (~90 KB, the type filter) and is
// only on screen after switching to the Search view. One wrapper, so the
// desktop sidebar and the mobile drawer split it the same way.
const SearchPanel = lazy(() => import("./search-panel"));

export default function LazySearchPanel(props: ComponentProps<typeof SearchPanelComponent>) {
	return (
		<Suspense fallback={null}>
			<SearchPanel {...props} />
		</Suspense>
	);
}
