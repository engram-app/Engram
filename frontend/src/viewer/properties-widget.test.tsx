import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { describe, expect, test, vi } from "vitest";
import * as Y from "yjs";
import { addKey, readRows, setValue } from "../crdt/frontmatter-doc";
import { PropertiesWidget } from "./properties-widget";

describe("PropertiesWidget", () => {
	test("renders rows from the doc and writes value edits back", async () => {
		const doc = new Y.Doc();
		addKey(doc, "title", "text");
		setValue(doc, "title", "Hi");
		render(<PropertiesWidget doc={doc} />);
		const input = await screen.findByDisplayValue("Hi");
		fireEvent.change(input, { target: { value: "Bye" } });
		fireEvent.blur(input);
		expect(readRows(doc).find((r) => r.key === "title")?.value).toBe("Bye");
	});

	test("reflects a remote add live", async () => {
		const doc = new Y.Doc();
		render(<PropertiesWidget doc={doc} />);
		addKey(doc, "author", "text"); // simulate remote mutation
		await waitFor(() => expect(screen.getByText("author")).toBeInTheDocument());
	});

	test("add property row appends a key", async () => {
		const doc = new Y.Doc();
		// Seeded: the widget hides itself (and its adder) on a note with no
		// frontmatter, so there has to be a row for the inline adder to exist.
		addKey(doc, "title", "text");
		render(<PropertiesWidget doc={doc} />);
		fireEvent.change(screen.getByPlaceholderText("Property name"), { target: { value: "status" } });
		fireEvent.click(screen.getByRole("button", { name: /add property/i }));
		await waitFor(() => expect(readRows(doc).map((r) => r.key)).toContain("status"));
	});

	// Naming a property is only half the job — the point of adding one is to
	// give it a value, so the caret has to end up there.
	test("adding a property leaves its value ready to type into", async () => {
		const doc = new Y.Doc();
		render(<PropertiesWidget doc={doc} />);
		addKey(doc, "seed", "text"); // make the widget visible
		const name = await screen.findByPlaceholderText("Property name");
		fireEvent.change(name, { target: { value: "status" } });
		fireEvent.keyDown(name, { key: "Enter" });

		const row = await screen.findByTestId("property-row-status");
		expect(within(row).getByRole("textbox")).toHaveFocus();
	});

	// An empty frontmatter block is a bordered strip of nothing above every
	// note that never got a property. Obsidian hides it; so do we.
	describe("when the note has no frontmatter", () => {
		test("renders nothing at all", () => {
			const { container } = render(<PropertiesWidget doc={new Y.Doc()} />);
			expect(screen.queryByTestId("note-properties")).not.toBeInTheDocument();
			expect(container).toBeEmptyDOMElement();
		});

		// Hidden must mean "returns null while still observing", not
		// "unmounted" — otherwise nothing is listening to bring it back.
		test("appears as soon as a property arrives", async () => {
			const doc = new Y.Doc();
			render(<PropertiesWidget doc={doc} />);
			expect(screen.queryByTestId("note-properties")).not.toBeInTheDocument();
			addKey(doc, "status", "text");
			await waitFor(() => expect(screen.getByTestId("note-properties")).toBeInTheDocument());
		});

		// The `---` gesture opens the editor before any property exists. That
		// "open but empty" state is LOCAL — it must never reach the Y.Doc, or an
		// empty properties block would sync to the user's other devices.
		describe("draft mode", () => {
			test("shows the empty editor and puts the caret in the name field", async () => {
				render(<PropertiesWidget doc={new Y.Doc()} draft onAbandonDraft={() => {}} />);
				expect(screen.getByTestId("note-properties")).toBeInTheDocument();
				await waitFor(() => expect(screen.getByPlaceholderText("Property name")).toHaveFocus());
			});

			// Clicking dead space is the ordinary way out, and it focuses nothing —
			// which is exactly the case a relatedTarget check would miss.
			test("abandons on a click outside when nothing was added", () => {
				const onAbandonDraft = vi.fn();
				render(<PropertiesWidget doc={new Y.Doc()} draft onAbandonDraft={onAbandonDraft} />);
				fireEvent.pointerDown(document.body);
				expect(onAbandonDraft).toHaveBeenCalled();
			});

			test("abandons on tabbing away", () => {
				const onAbandonDraft = vi.fn();
				render(<PropertiesWidget doc={new Y.Doc()} draft onAbandonDraft={onAbandonDraft} />);
				fireEvent.focusIn(document.body);
				expect(onAbandonDraft).toHaveBeenCalled();
			});

			test("stays once a property was added", () => {
				const onAbandonDraft = vi.fn();
				render(<PropertiesWidget doc={new Y.Doc()} draft onAbandonDraft={onAbandonDraft} />);
				fireEvent.change(screen.getByPlaceholderText("Property name"), {
					target: { value: "status" },
				});
				fireEvent.click(screen.getByRole("button", { name: /add property/i }));
				fireEvent.pointerDown(document.body);
				expect(onAbandonDraft).not.toHaveBeenCalled();
			});

			// Radix portals its menu to document.body, so a click on a type option
			// lands OUTSIDE the widget's root — the dismissal must not read that
			// as clicking away, or picking a type destroys the draft.
			test("picking a property type does not abandon the draft", async () => {
				const onAbandonDraft = vi.fn();
				render(<PropertiesWidget doc={new Y.Doc()} draft onAbandonDraft={onAbandonDraft} />);
				const trigger = screen.getByRole("button", { name: "Property type" });
				fireEvent.pointerDown(trigger, { button: 0, ctrlKey: false });
				fireEvent.click(trigger);
				const option = await screen.findByRole("menuitem", { name: "number" });
				fireEvent.pointerDown(option);
				fireEvent.click(option);
				expect(onAbandonDraft).not.toHaveBeenCalled();
			});

			test("does not abandon on interaction inside the editor", () => {
				const onAbandonDraft = vi.fn();
				render(<PropertiesWidget doc={new Y.Doc()} draft onAbandonDraft={onAbandonDraft} />);
				fireEvent.pointerDown(screen.getByRole("button", { name: /add property/i }));
				expect(onAbandonDraft).not.toHaveBeenCalled();
			});
		});

		test("goes away again when the last property is removed", async () => {
			const doc = new Y.Doc();
			addKey(doc, "status", "text");
			render(<PropertiesWidget doc={doc} />);
			fireEvent.click(await screen.findByRole("button", { name: "Remove status" }));
			await waitFor(() => expect(screen.queryByTestId("note-properties")).not.toBeInTheDocument());
		});
	});

	test("does not clobber a field being actively edited by a remote update", async () => {
		const doc = new Y.Doc();
		addKey(doc, "title", "text");
		setValue(doc, "title", "Hi");
		render(<PropertiesWidget doc={doc} />);
		const input = (await screen.findByDisplayValue("Hi")) as HTMLInputElement;
		input.focus();
		fireEvent.change(input, { target: { value: "Draft" } });
		setValue(doc, "title", "RemoteWins"); // remote update while focused
		await waitFor(() =>
			expect(readRows(doc).find((r) => r.key === "title")?.value).toBe("RemoteWins"),
		);
		expect(input.value).toBe("Draft"); // local draft preserved while focused
	});
});
