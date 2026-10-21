import { render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { Toaster } from "@/components/ui/sonner";
import { offerLocaleSwitch } from "./translation-prompt";

// The offer can fire before the lazily loaded <Toaster> has mounted (a
// browser set to always translate does it at first paint), and the target is
// marked seen for the session by then. sonner (2.x) keeps active toasts and
// replays them to a Toaster that subscribes later; this pins that, so a
// sonner change that drops early toasts fails here instead of silently
// losing the offer for the whole session.
describe("offerLocaleSwitch before the Toaster mounts", () => {
	it("is shown once the Toaster mounts", async () => {
		window.localStorage.clear();
		await offerLocaleSwitch("de", { locale: "en", setLocale: vi.fn(), loaders: {} });

		render(<Toaster />);

		expect(await screen.findByText("Show Engram in Deutsch?")).toBeInTheDocument();
	});
});
