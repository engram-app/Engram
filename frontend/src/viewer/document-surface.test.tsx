import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DocumentSurface } from "./document-surface";
import {
	clampDocumentWidth,
	DEFAULT_DOCUMENT_WIDTH,
	DOCUMENT_WIDTH_KEY,
	MAX_DOCUMENT_WIDTH,
	MIN_DOCUMENT_WIDTH,
	readDocumentWidth,
} from "./document-width";

// jsdom has no PointerEvent, and fireEvent falls back to a plain Event that
// drops clientX. A MouseEvent subclass carries the coordinates the drag reads.
class TestPointerEvent extends MouseEvent {
	pointerId: number;
	constructor(type: string, init: MouseEventInit & { pointerId?: number } = {}) {
		super(type, init);
		this.pointerId = init.pointerId ?? 1;
	}
}

beforeEach(() => {
	window.localStorage.clear();
	vi.stubGlobal("PointerEvent", TestPointerEvent);
	// Layout does not exist in jsdom: the column renders as wide as its max-width
	// says (the default until the test changes it), like it would with room to spare.
	vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (
		this: HTMLElement,
	) {
		const width = Number.parseFloat(this.style.maxWidth) || DEFAULT_DOCUMENT_WIDTH;
		return {
			width,
			height: 600,
			top: 0,
			left: 0,
			right: width,
			bottom: 600,
			x: 0,
			y: 0,
			toJSON: () => ({}),
		};
	});
	setAvailableWidth(1600);
});
// The space the column is centred in, which caps how wide it can be dragged.
function setAvailableWidth(px: number) {
	vi.spyOn(HTMLElement.prototype, "clientWidth", "get").mockReturnValue(px);
}

afterEach(() => {
	vi.restoreAllMocks();
	vi.unstubAllGlobals();
});

const surface = () => screen.getByTestId("document-surface");
const rightEdge = () => screen.getByRole("separator", { name: /right edge/i });
const leftEdge = () => screen.getByRole("separator", { name: /left edge/i });
const widthOf = () => surface().style.maxWidth;

function drag(handle: HTMLElement, fromX: number, toX: number) {
	fireEvent.pointerDown(handle, { clientX: fromX, button: 0, pointerId: 1 });
	fireEvent.pointerMove(handle, { clientX: toX, pointerId: 1 });
	fireEvent.pointerUp(handle, { clientX: toX, pointerId: 1 });
}

function renderSurface() {
	return render(
		<DocumentSurface>
			<p>hello</p>
		</DocumentSurface>,
	);
}

describe("document width storage", () => {
	it("clamps to the allowed range and falls back to the default for junk", () => {
		expect(clampDocumentWidth(10)).toBe(MIN_DOCUMENT_WIDTH);
		expect(clampDocumentWidth(99_999)).toBe(MAX_DOCUMENT_WIDTH);
		expect(clampDocumentWidth(700)).toBe(700);
		expect(clampDocumentWidth(Number.NaN)).toBe(DEFAULT_DOCUMENT_WIDTH);
	});

	it("reads a stored width, and ignores garbage", () => {
		expect(readDocumentWidth()).toBe(DEFAULT_DOCUMENT_WIDTH);
		window.localStorage.setItem(DOCUMENT_WIDTH_KEY, "960");
		expect(readDocumentWidth()).toBe(960);
		window.localStorage.setItem(DOCUMENT_WIDTH_KEY, "wide please");
		expect(readDocumentWidth()).toBe(DEFAULT_DOCUMENT_WIDTH);
		window.localStorage.setItem(DOCUMENT_WIDTH_KEY, "5");
		expect(readDocumentWidth()).toBe(MIN_DOCUMENT_WIDTH);
	});
});

describe("DocumentSurface", () => {
	it("renders its children at the default width", () => {
		renderSurface();
		expect(screen.getByText("hello")).toBeInTheDocument();
		expect(widthOf()).toBe(`${DEFAULT_DOCUMENT_WIDTH}px`);
	});

	it("starts at the saved width", () => {
		window.localStorage.setItem(DOCUMENT_WIDTH_KEY, "1000");
		renderSurface();
		expect(widthOf()).toBe("1000px");
	});

	it("dragging the right edge out widens the column on both sides", () => {
		renderSurface();
		drag(rightEdge(), 1000, 1050);
		expect(widthOf()).toBe(`${DEFAULT_DOCUMENT_WIDTH + 100}px`);
	});

	it("dragging the left edge out widens it, dragging in narrows it", () => {
		renderSurface();
		drag(leftEdge(), 300, 250);
		expect(widthOf()).toBe(`${DEFAULT_DOCUMENT_WIDTH + 100}px`);
		drag(leftEdge(), 250, 300);
		expect(widthOf()).toBe(`${DEFAULT_DOCUMENT_WIDTH}px`);
	});

	it("saves the width when the drag ends, not on every move", () => {
		renderSurface();
		fireEvent.pointerDown(rightEdge(), { clientX: 1000, button: 0, pointerId: 1 });
		fireEvent.pointerMove(rightEdge(), { clientX: 1040, pointerId: 1 });
		expect(window.localStorage.getItem(DOCUMENT_WIDTH_KEY)).toBeNull();
		fireEvent.pointerUp(rightEdge(), { clientX: 1040, pointerId: 1 });
		expect(window.localStorage.getItem(DOCUMENT_WIDTH_KEY)).toBe(
			String(DEFAULT_DOCUMENT_WIDTH + 80),
		);
	});

	it("never grows past the space it is centred in", () => {
		setAvailableWidth(900);
		renderSurface();
		drag(rightEdge(), 1000, 6000);
		expect(widthOf()).toBe("900px");
	});

	it("never goes below the minimum", () => {
		renderSurface();
		drag(rightEdge(), 1000, -5000);
		expect(widthOf()).toBe(`${MIN_DOCUMENT_WIDTH}px`);
	});

	it("lights up only the edge being dragged", () => {
		renderSurface();
		expect(rightEdge()).toHaveAttribute("data-dragging", "false");
		fireEvent.pointerDown(rightEdge(), { clientX: 1000, button: 0, pointerId: 1 });
		expect(rightEdge()).toHaveAttribute("data-dragging", "true");
		expect(leftEdge()).toHaveAttribute("data-dragging", "false");
		fireEvent.pointerUp(rightEdge(), { clientX: 1000, pointerId: 1 });
		expect(rightEdge()).toHaveAttribute("data-dragging", "false");
		fireEvent.pointerDown(leftEdge(), { clientX: 300, button: 0, pointerId: 1 });
		expect(leftEdge()).toHaveAttribute("data-dragging", "true");
		expect(rightEdge()).toHaveAttribute("data-dragging", "false");
	});

	it("ignores moves when no drag is in progress", () => {
		renderSurface();
		fireEvent.pointerMove(rightEdge(), { clientX: 5000, pointerId: 1 });
		expect(widthOf()).toBe(`${DEFAULT_DOCUMENT_WIDTH}px`);
	});

	it("double-click resets to the default and clears the saved width", () => {
		window.localStorage.setItem(DOCUMENT_WIDTH_KEY, "1100");
		renderSurface();
		fireEvent.doubleClick(rightEdge());
		expect(widthOf()).toBe(`${DEFAULT_DOCUMENT_WIDTH}px`);
		expect(window.localStorage.getItem(DOCUMENT_WIDTH_KEY)).toBeNull();
	});

	it("arrow keys resize from the keyboard, mirrored on the left edge", () => {
		renderSurface();
		fireEvent.keyDown(rightEdge(), { key: "ArrowRight" });
		const widened = Number.parseInt(widthOf(), 10);
		expect(widened).toBeGreaterThan(DEFAULT_DOCUMENT_WIDTH);
		fireEvent.keyDown(leftEdge(), { key: "ArrowRight" });
		expect(Number.parseInt(widthOf(), 10)).toBe(DEFAULT_DOCUMENT_WIDTH);
	});

	it("exposes the width to assistive tech", () => {
		renderSurface();
		const handle = rightEdge();
		expect(handle).toHaveAttribute("aria-orientation", "vertical");
		expect(handle).toHaveAttribute("aria-valuenow", String(DEFAULT_DOCUMENT_WIDTH));
		expect(handle).toHaveAttribute("aria-valuemin", String(MIN_DOCUMENT_WIDTH));
		act(() => handle.focus());
		expect(handle).toHaveFocus();
	});
});
