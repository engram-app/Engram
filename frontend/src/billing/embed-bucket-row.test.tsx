import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { EmbedBucket } from "@/api/queries";
import EmbedBucketRow from "./embed-bucket-row";

const state = vi.hoisted(() => ({ bucket: null as EmbedBucket | null }));

vi.mock("@/api/queries", () => ({
	useEmbedBucket: () => ({ data: state.bucket }),
}));

describe("EmbedBucketRow", () => {
	beforeEach(() => {
		state.bucket = null;
	});

	it("renders nothing for a user with no bucket", () => {
		const { container } = render(<EmbedBucketRow />);
		expect(container).toBeEmptyDOMElement();
	});

	it("shows a full bucket as full", () => {
		state.bucket = {
			available: 6_000_000,
			capacity: 6_000_000,
			refill_per_day: 16_438,
			full_at: null,
		};
		render(<EmbedBucketRow />);
		expect(screen.getByText("Indexing budget")).toBeInTheDocument();
		expect(screen.getByText(/6,000,000 of 6,000,000 tokens left/)).toBeInTheDocument();
		expect(screen.getByText("Full")).toBeInTheDocument();
	});

	it("says how fast a spent bucket refills and when it is full", () => {
		state.bucket = {
			available: 1500,
			capacity: 6_000_000,
			refill_per_day: 16_438,
			full_at: "2027-10-20T12:00:00Z",
		};
		render(<EmbedBucketRow />);
		expect(screen.getByText(/1,500 of 6,000,000 tokens left/)).toBeInTheDocument();
		expect(screen.getByText(/Refills 16,438 a day, full again on/)).toBeInTheDocument();
		expect(screen.queryByText(/searchable by keyword/)).toBeNull();
	});

	it("explains what an empty bucket means, so nothing stops silently", () => {
		state.bucket = {
			available: 0,
			capacity: 6_000_000,
			refill_per_day: 16_438,
			full_at: "2027-10-20T12:00:00Z",
		};
		render(<EmbedBucketRow />);
		expect(
			screen.getByText(
				"New notes are searchable by keyword now and get full search as your budget refills.",
			),
		).toBeInTheDocument();
	});
});
