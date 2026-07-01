import { useEffect, useRef, useState } from "react";
import { ACTIONS, EVENTS, type EventData, Joyride, STATUS, type Step } from "react-joyride";
import { useNavigate } from "react-router";
import { GATED_STEPS, tourSteps } from "./steps";

interface Props {
	active: boolean;
	onExit: (reachedEnd: boolean) => void;
	reachedEnd: boolean;
	setReachedEnd: (v: boolean) => void;
}

export function TourController({ active, onExit, setReachedEnd }: Props) {
	const navigate = useNavigate();
	// Stash callbacks behind refs so React-Joyride's event handler always sees
	// the latest closures without us re-mounting on every parent render.
	const onExitRef = useRef(onExit);
	const setReachedEndRef = useRef(setReachedEnd);
	onExitRef.current = onExit;
	setReachedEndRef.current = setReachedEnd;

	// Controlled stepIndex so we can advance gated steps from a target click
	// listener (joyride's continuous mode otherwise drives index internally).
	const [stepIndex, setStepIndex] = useState(0);

	// Reset to first step whenever the tour (re)starts.
	useEffect(() => {
		if (active) {
			setStepIndex(0);
		}
	}, [active]);

	// The final step targets `[data-tour="dashboard-root"]` which only exists
	// on the dashboard route. If the user opened a demo note during step 1,
	// we're on /note/<id> and Joyride times out waiting for that target.
	// Bounce back to / when we land on the final step.
	useEffect(() => {
		if (!active) {
			return;
		}
		if (stepIndex === tourSteps.length - 1) {
			navigate("/", { replace: true });
		}
	}, [active, stepIndex, navigate]);

	// Gated steps: hide the Next button + advance only when the user performs
	// the configured interaction. The step declares which window CustomEvent
	// signals success (e.g. step 0 waits for `engram:vault-switched`).
	useEffect(() => {
		if (!active) {
			return;
		}
		const eventName = GATED_STEPS[stepIndex];
		if (!eventName) {
			return;
		}

		const handler = () => setStepIndex((i) => i + 1);
		window.addEventListener(eventName, handler, { once: true });
		return () => window.removeEventListener(eventName, handler);
	}, [active, stepIndex]);

	const handle = (data: EventData) => {
		const { status, index, action, type } = data;

		if (type === EVENTS.STEP_AFTER) {
			if (action === ACTIONS.NEXT) {
				if (index === tourSteps.length - 1) {
					// Push stepIndex out of range so joyride transitions to
					// STATUS.FINISHED and cleans up its overlay/spotlight elements.
					// We then exit via the status branch below.
					setReachedEndRef.current(true);
					setStepIndex(tourSteps.length);
					return;
				}
				setStepIndex(index + 1);
			} else if (action === ACTIONS.PREV) {
				setStepIndex(Math.max(0, index - 1));
			}
			return;
		}

		if (status === STATUS.FINISHED || status === STATUS.SKIPPED) {
			onExitRef.current(status === STATUS.FINISHED);
		}
	};

	return (
		<Joyride
			steps={tourSteps as Step[]}
			run={active}
			stepIndex={stepIndex}
			continuous
			onEvent={handle}
			locale={{ last: "Create my vault", skip: "Skip" }}
			options={{
				showProgress: true,
				zIndex: 60, // sits above shadcn dialogs (z-50)
				// ESC closes; overlay click is a no-op (no overlay dismissal).
				overlayClickAction: false,
				// Show skip button alongside back+primary.
				buttons: ["skip", "back", "primary"],
				// Pick up the design tokens. In this app the CSS vars are full
				// oklch() colors (see frontend/src/main.css), so reference them
				// directly — wrapping in hsl() yields invalid CSS and the popover
				// background falls back to transparent.
				primaryColor: "var(--primary)",
				backgroundColor: "var(--popover)",
				textColor: "var(--popover-foreground)",
				arrowColor: "var(--popover)",
				overlayColor: "rgba(0, 0, 0, 0.45)",
			}}
		/>
	);
}
