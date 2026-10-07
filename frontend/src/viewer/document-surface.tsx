import {
	type KeyboardEvent,
	type ReactNode,
	type PointerEvent as ReactPointerEvent,
	useRef,
	useState,
} from "react";
import { useT } from "@/i18n/locale-provider";
import {
	clampDocumentWidth,
	DEFAULT_DOCUMENT_WIDTH,
	MAX_DOCUMENT_WIDTH,
	MIN_DOCUMENT_WIDTH,
	readDocumentWidth,
	writeDocumentWidth,
} from "./document-width";

/** Pixels the column grows or shrinks per arrow-key press. */
const KEY_STEP = 32;

type Side = "left" | "right";

interface Drag {
	side: Side;
	startX: number;
	startWidth: number;
	/** Widest the column can usefully be: the space it is centred in. */
	available: number;
	width: number;
}

// A transparent grab band straddling the column's border, mostly OUTSIDE it so
// it never covers the page scrollbar on the inside. The border stays a hairline;
// an accent bar reveals itself over the band on hover, focus and drag, the same
// pattern as the sidebar handles (components/ui/resizable.tsx).
const HANDLE_BASE =
	"absolute inset-y-0 z-10 hidden w-2.5 cursor-col-resize touch-none focus-visible:outline-hidden md:block " +
	"after:pointer-events-none after:absolute after:inset-y-0 after:w-1 after:-translate-x-1/2 after:rounded-full after:bg-primary/50 after:opacity-0 after:transition-opacity after:content-[''] " +
	"hover:after:opacity-100 hover:after:delay-100 focus-visible:after:opacity-100 " +
	"data-[dragging=true]:after:bg-primary data-[dragging=true]:after:opacity-100";

// Box spans 2px inside the border to 8px outside it; the bar sits on the border.
const HANDLE_SIDE: Record<Side, string> = {
	right: "-right-2 after:left-[2px]",
	left: "-left-2 after:left-[8px]",
};

// The white paper column a note renders on. Shared so states that stand in for a
// note (not-found, etc.) sit on the same surface instead of the bare grid. Its
// width is user-resizable from either edge (symmetrically, since it is centred).
export function DocumentSurface({ children }: { children: ReactNode }) {
	const { t } = useT();
	const [width, setWidth] = useState(readDocumentWidth);
	const [dragging, setDragging] = useState<Side | null>(null);
	const wrapperRef = useRef<HTMLDivElement>(null);
	const drag = useRef<Drag | null>(null);

	const commit = (next: number) => {
		setWidth(next);
		writeDocumentWidth(next);
	};

	const onPointerDown = (side: Side) => (e: ReactPointerEvent<HTMLDivElement>) => {
		const wrapper = wrapperRef.current;
		if (e.button !== 0 || !wrapper) {
			return;
		}
		e.preventDefault();
		// Start from the RENDERED width: a narrow window can leave the column
		// narrower than its saved max-width, and the edge must follow the pointer
		// from where it actually is.
		const startWidth = wrapper.getBoundingClientRect().width;
		drag.current = {
			side,
			startX: e.clientX,
			startWidth,
			available: wrapper.parentElement?.clientWidth || MAX_DOCUMENT_WIDTH,
			width: startWidth,
		};
		setDragging(side);
		// Keeps the drag alive when the pointer leaves the thin handle. Best
		// effort: capture throws for a pointer the browser no longer considers
		// active, and the drag must still start.
		try {
			e.currentTarget.setPointerCapture?.(e.pointerId);
		} catch {
			// ignore
		}
	};

	const onPointerMove = (e: ReactPointerEvent<HTMLDivElement>) => {
		const d = drag.current;
		if (!d) {
			return;
		}
		const dx = e.clientX - d.startX;
		// Centred column: each edge moves half the width change.
		const grow = d.side === "left" ? -dx : dx;
		const next = clampDocumentWidth(d.startWidth + grow * 2);
		d.width = Math.max(MIN_DOCUMENT_WIDTH, Math.min(next, d.available));
		setWidth(d.width);
	};

	const endDrag = (e: ReactPointerEvent<HTMLDivElement>) => {
		const d = drag.current;
		if (!d) {
			return;
		}
		drag.current = null;
		setDragging(null);
		e.currentTarget.releasePointerCapture?.(e.pointerId);
		if (d.width !== d.startWidth) {
			writeDocumentWidth(d.width);
		}
	};

	const onKeyDown = (side: Side) => (e: KeyboardEvent<HTMLDivElement>) => {
		if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") {
			return;
		}
		e.preventDefault();
		// Arrow toward the outside widens, toward the inside narrows.
		const outward = e.key === (side === "right" ? "ArrowRight" : "ArrowLeft");
		commit(clampDocumentWidth(width + (outward ? KEY_STEP : -KEY_STEP)));
	};

	const reset = () => {
		setWidth(DEFAULT_DOCUMENT_WIDTH);
		writeDocumentWidth(null);
	};

	const handle = (side: Side) => (
		// A separator you can drag and focus is a window splitter widget; biome's
		// semantic-element rule would swap it for an <hr>, which cannot take focus.
		// biome-ignore lint/a11y/useSemanticElements: window-splitter pattern
		<div
			role="separator"
			aria-orientation="vertical"
			aria-label={
				side === "left" ? t("Resize document, left edge") : t("Resize document, right edge")
			}
			aria-valuenow={Math.round(width)}
			aria-valuemin={MIN_DOCUMENT_WIDTH}
			aria-valuemax={MAX_DOCUMENT_WIDTH}
			tabIndex={0}
			data-dragging={dragging === side}
			className={`${HANDLE_BASE} ${HANDLE_SIDE[side]}`}
			onPointerDown={onPointerDown(side)}
			onPointerMove={onPointerMove}
			onPointerUp={endDrag}
			onPointerCancel={endDrag}
			onDoubleClick={reset}
			onKeyDown={onKeyDown(side)}
		/>
	);

	return (
		<div
			ref={wrapperRef}
			data-testid="document-surface"
			className="relative mx-auto size-full min-h-0 min-w-0 md:-my-6 md:h-[calc(100%+3rem)]"
			style={{ maxWidth: width }}
		>
			<section className="flex size-full min-h-0 min-w-0 flex-col overflow-hidden border-border border-x bg-card text-card-foreground">
				{children}
			</section>
			{handle("left")}
			{handle("right")}
		</div>
	);
}
