import { fireEvent, render, screen, waitFor } from "@testing-library/react";
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

	// The row being filled in is the ONLY row on a note with no properties, so
	// if it has nowhere to type a value there is nowhere to type one at all.
	test("the new-property row has a value field, not just a key", () => {
		render(<PropertiesWidget doc={new Y.Doc()} draft onAbandonDraft={() => {}} />);
		expect(screen.getByPlaceholderText("Property name")).toBeInTheDocument();
		expect(screen.getByPlaceholderText("Value")).toBeInTheDocument();
	});

	test("commits key and value together, then waits for the next property", async () => {
		const doc = new Y.Doc();
		render(<PropertiesWidget doc={doc} draft onAbandonDraft={() => {}} />);
		fireEvent.change(screen.getByPlaceholderText("Property name"), {
			target: { value: "status" },
		});
		fireEvent.change(screen.getByPlaceholderText("Value"), { target: { value: "draft" } });
		fireEvent.keyDown(screen.getByPlaceholderText("Value"), { key: "Enter" });

		await waitFor(() => expect(readRows(doc).find((r) => r.key === "status")?.value).toBe("draft"));
		expect(screen.getByPlaceholderText("Property name")).toHaveFocus();
		expect(screen.getByPlaceholderText("Property name")).toHaveValue("");
	});

	test("Enter in the key field moves to the value rather than committing early", () => {
		const doc = new Y.Doc();
		render(<PropertiesWidget doc={doc} draft onAbandonDraft={() => {}} />);
		const name = screen.getByPlaceholderText("Property name");
		fireEvent.change(name, { target: { value: "status" } });
		fireEvent.keyDown(name, { key: "Enter" });

		expect(screen.getByPlaceholderText("Value")).toHaveFocus();
		expect(readRows(doc)).toHaveLength(0);
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

			// Clicking away from a property you just filled in should keep it. The
			// draft has committed nothing yet, so a naive "is the doc empty?" check
			// throws the typed key and value away.
			test("commits what was typed instead of discarding it", () => {
				const doc = new Y.Doc();
				const onAbandonDraft = vi.fn();
				render(<PropertiesWidget doc={doc} draft onAbandonDraft={onAbandonDraft} />);
				fireEvent.change(screen.getByPlaceholderText("Property name"), {
					target: { value: "status" },
				});
				fireEvent.change(screen.getByPlaceholderText("Value"), { target: { value: "draft" } });

				fireEvent.pointerDown(document.body);

				// Synchronous: the commit writes to the Y.Doc inside the handler.
				expect(readRows(doc).find((r) => r.key === "status")?.value).toBe("draft");
				expect(onAbandonDraft).not.toHaveBeenCalled();
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
