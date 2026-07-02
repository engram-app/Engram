// Barrel for the authenticated app shell. The router lazy()-imports every
// layout through THIS module so they land in ONE async chunk — four separate
// lazy(() => import("./x")) calls would nest three Suspense boundaries into a
// sequential chunk-fetch waterfall (gate → shell → app-layout) on every
// signed-in load. Keeping the shell out of the eager entry is what keeps
// yjs/phoenix/react-joyride/react-resizable-panels off the sign-in page's
// critical path.

export { default as OnboardingGate } from "../onboarding/onboarding-gate";
export { OnboardingShell } from "../onboarding/onboarding-shell";
export { default as SettingsLayout } from "../settings/settings-layout";
export { default as AppLayout } from "./app-layout";
