/* Fallback version stamp for ToS acceptance. The authoritative version comes
 * from the backend (onboarding status `current_tos_version`); this is only used
 * if that is absent. The terms/privacy prose itself lives on the marketing site
 * (engram.page/terms, /privacy) — the app links out rather than duplicating it. */
export const TERMS_VERSION = '2026-05-24'
