import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, test } from "vitest";
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
