import { fireEvent, render, renderHook, screen } from "@testing-library/react";
import { act } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { findMoveClashes, useAttachmentMove } from "./move-clash";

const move = vi.fn();
const rename = vi.fn();
let mockAttachments: { path: string }[] = [];
vi.mock("@/api/queries", () => ({
	useAttachments: () => ({ data: mockAttachments }),
	useBatchMoveAttachments: () => ({ mutateAsync: move, mutate: move }),
	useRenameAttachment: () => ({ mutate: rename }),
}));

beforeEach(() => {
	move.mockReset();
	rename.mockReset();
	mockAttachments = [];
});

describe("findMoveClashes", () => {
	const vault = [{ path: "music/Song.flac" }, { path: "a/song.flac" }, { path: "a/other.png" }];

	it("flags a file whose name is taken in the target, ignoring case", () => {
		expect(findMoveClashes(["a/song.flac", "a/other.png"], "music", vault)).toEqual([
			"a/song.flac",
		]);
	});

	it("a file already in the target is not a clash with itself", () => {
		expect(findMoveClashes(["music/Song.flac"], "music", vault)).toEqual([]);
	});

	it("two moved files with one name clash with each other", () => {
		const v = [{ path: "a/x.png" }, { path: "b/x.png" }];
		expect(findMoveClashes(["a/x.png", "b/x.png"], "c", v)).toEqual(["b/x.png"]);
	});
});

function setup() {
	const hook = renderHook(() => useAttachmentMove());
	const ui = () => render(hook.result.current.dialog);
	return { hook, ui };
}

describe("useAttachmentMove", () => {
	it("moves straight through when nothing clashes", () => {
		mockAttachments = [{ path: "a/x.png" }];
		const { hook } = setup();
		act(() => hook.result.current.move(["a/x.png"], "b"));
		expect(move).toHaveBeenCalledWith({ paths: ["a/x.png"], target_folder: "b" });
		expect(hook.result.current.dialog).toBeNull();
	});

	it("asks for a new name for one clashing file, prefilled free, extension kept", () => {
		mockAttachments = [{ path: "a/song.flac" }, { path: "music/song.flac" }];
		const { hook, ui } = setup();
		act(() => hook.result.current.move(["a/song.flac"], "music"));
		expect(move).not.toHaveBeenCalled();
		ui();
		expect(screen.getByRole("dialog")).toHaveTextContent(
			"music already has a file named song.flac",
		);
		const box = screen.getByRole("textbox");
		expect(box).toHaveValue("song 1");
		fireEvent.change(box, { target: { value: "song live" } });
		fireEvent.click(screen.getByRole("button", { name: "Move" }));
		expect(rename).toHaveBeenCalledWith({
			old_path: "a/song.flac",
			new_path: "music/song live.flac",
		});
	});

	it("will not move onto another taken name", () => {
		mockAttachments = [
			{ path: "a/song.flac" },
			{ path: "music/song.flac" },
			{ path: "music/b.flac" },
		];
		const { hook, ui } = setup();
		act(() => hook.result.current.move(["a/song.flac"], "music"));
		ui();
		fireEvent.change(screen.getByRole("textbox"), { target: { value: "B" } });
		expect(screen.getByRole("button", { name: "Move" })).toBeDisabled();
		expect(screen.getByText(/that name is taken too/iu)).toBeInTheDocument();
	});

	it("for several, moves the rest and numbers the clashing ones on Keep both", async () => {
		mockAttachments = [
			{ path: "a/song.flac" },
			{ path: "a/new.png" },
			{ path: "music/song.flac" },
			{ path: "music/song 1.flac" },
		];
		const { hook, ui } = setup();
		act(() => hook.result.current.move(["a/song.flac", "a/new.png", "a/x.png"], "music"));
		ui();
		await act(async () => {
			fireEvent.click(screen.getByRole("button", { name: /keep both/iu }));
		});
		expect(move).toHaveBeenCalledWith({ paths: ["a/new.png", "a/x.png"], target_folder: "music" });
		expect(rename).toHaveBeenCalledWith({ old_path: "a/song.flac", new_path: "music/song 2.flac" });
	});

	it("Keep both numbers a capitalised name instead of re-sending the taken one", async () => {
		mockAttachments = [{ path: "a/IMG_1.JPG" }, { path: "a/b.png" }, { path: "cam/IMG_1.JPG" }];
		const { hook, ui } = setup();
		act(() => hook.result.current.move(["a/IMG_1.JPG", "a/b.png"], "cam"));
		ui();
		await act(async () => {
			fireEvent.click(screen.getByRole("button", { name: /keep both/iu }));
		});
		expect(rename).toHaveBeenCalledWith({ old_path: "a/IMG_1.JPG", new_path: "cam/IMG_1 1.JPG" });
	});

	it("the one-file box opens on a free name even when the taken one is capitalised", () => {
		mockAttachments = [{ path: "a/IMG_1.JPG" }, { path: "cam/IMG_1.JPG" }];
		const { hook, ui } = setup();
		act(() => hook.result.current.move(["a/IMG_1.JPG"], "cam"));
		ui();
		expect(screen.getByRole("textbox")).toHaveValue("IMG_1 1");
		expect(screen.queryByText(/that name is taken too/iu)).not.toBeInTheDocument();
	});

	it("Keep both avoids names the same move is bringing in, and renames after the move lands", async () => {
		mockAttachments = [{ path: "a/x.png" }, { path: "b/x.png" }, { path: "d/x 1.png" }];
		const { hook, ui } = setup();
		act(() => hook.result.current.move(["a/x.png", "b/x.png", "d/x 1.png"], "c"));
		ui();
		let release: () => void = () => undefined;
		move.mockReturnValue(
			new Promise<void>((r) => {
				release = r;
			}),
		);
		await act(async () => {
			fireEvent.click(screen.getByRole("button", { name: /keep both/iu }));
		});
		expect(move).toHaveBeenCalledWith({ paths: ["a/x.png", "d/x 1.png"], target_folder: "c" });
		// Not before the batch has landed: the two would race for one name.
		expect(rename).not.toHaveBeenCalled();
		await act(async () => {
			release();
		});
		expect(rename).toHaveBeenCalledWith({ old_path: "b/x.png", new_path: "c/x 2.png" });
	});

	it("Keep both says the folder has the name when it does", () => {
		mockAttachments = [{ path: "a/x.png" }, { path: "a/y.png" }, { path: "c/x.png" }];
		const { hook, ui } = setup();
		act(() => hook.result.current.move(["a/x.png", "a/y.png"], "c"));
		ui();
		expect(screen.getByText("c already has a file with this name")).toBeInTheDocument();
	});

	it("Keep both does not blame the folder for two moved files sharing a name", () => {
		mockAttachments = [{ path: "a/x.png" }, { path: "b/x.png" }];
		const { hook, ui } = setup();
		act(() => hook.result.current.move(["a/x.png", "b/x.png"], "c"));
		ui();
		expect(screen.queryByText(/already has/iu)).not.toBeInTheDocument();
		expect(screen.getByText("This file would share a name with another in c")).toBeInTheDocument();
	});

	it("Cancel moves nothing", () => {
		mockAttachments = [{ path: "a/song.flac" }, { path: "music/song.flac" }];
		const { hook, ui } = setup();
		act(() => hook.result.current.move(["a/song.flac"], "music"));
		ui();
		fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
		expect(move).not.toHaveBeenCalled();
		expect(rename).not.toHaveBeenCalled();
	});
});
