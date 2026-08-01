import type { EditorView } from "@codemirror/view";
import { act, renderHook } from "@testing-library/react";
import type { ReactNode } from "react";
import { describe, expect, it } from "vitest";
import { ActiveEditorProvider, useActiveEditor } from "./active-editor-context";

const wrapper = ({ children }: { children: ReactNode }) => (
	<ActiveEditorProvider>{children}</ActiveEditorProvider>
);

// Stand-in for a CodeMirror view — nothing here touches its API.
const fakeView = { dispatch: () => {} } as unknown as EditorView;

describe("ActiveEditorProvider", () => {
	it("reports no editor before one is published", () => {
		const { result } = renderHook(() => useActiveEditor(), { wrapper });
		expect(result.current.hasEditor).toBe(false);
		expect(result.current.getView()).toBeNull();
	});

	it("exposes a published editor and flips hasEditor", () => {
		const { result } = renderHook(() => useActiveEditor(), { wrapper });
		act(() => result.current.setEditor(() => fakeView));
		expect(result.current.hasEditor).toBe(true);
		expect(result.current.getView()).toBe(fakeView);
	});

	it("stores the accessor instead of invoking it as a state updater", () => {
		// Guards the functional-update form in setEditor: a bare setGetter(fn)
		// would make React CALL fn and store its RETURN VALUE, so getView() would
		// blow up (or silently return the view instead of the accessor).
		let calls = 0;
		const { result } = renderHook(() => useActiveEditor(), { wrapper });
		act(() =>
			result.current.setEditor(() => {
				calls += 1;
				return fakeView;
			}),
		);
		expect(calls).toBe(0);
		expect(result.current.getView()).toBe(fakeView);
		expect(calls).toBe(1);
	});

	it("clears back to null when the editor unmounts", () => {
		const { result } = renderHook(() => useActiveEditor(), { wrapper });
		act(() => result.current.setEditor(() => fakeView));
		act(() => result.current.setEditor(null));
		expect(result.current.hasEditor).toBe(false);
		expect(result.current.getView()).toBeNull();
	});

	it("reports no editor when the accessor resolves to null mid-teardown", () => {
		// The note page publishes `() => editorViewRef.current`, which is briefly
		// null between mount and CodeMirror's onView callback.
		const { result } = renderHook(() => useActiveEditor(), { wrapper });
		act(() => result.current.setEditor(() => null));
		expect(result.current.getView()).toBeNull();
	});

	it("throws when used outside the provider", () => {
		expect(() => renderHook(() => useActiveEditor())).toThrow(/ActiveEditorProvider/u);
	});
});
