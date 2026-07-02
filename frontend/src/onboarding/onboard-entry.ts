// Barrel for the onboarding entry surface (layout + index redirect), lazy()-
// imported by the router through this single module so both land in one async
// chunk instead of a nested lazy waterfall. Individual wizard steps stay as
// their own lazy chunks. See layout/app-shell.ts for the same pattern.
export { default as OnboardLayout } from "./onboard-layout";
export { default as OnboardRedirect } from "./onboard-redirect";
