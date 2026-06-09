import { useBillingStatus } from "../api/queries"

export interface ConnectionCapState {
  isLoading: boolean
  atCap: boolean
  limit: number | null
  current: number
}

/**
 * Reads the cap shape for a connection kind from the bundled `/billing/status`
 * response. Returns `atCap` true only when there's a positive integer limit
 * AND the user is at or above it — a `null` (unlimited) limit is never at cap.
 *
 * Used by the proactive cap UI on /link and /oauth/consent to swap the normal
 * flow for the disconnect panel without an extra fetch.
 */
export function useConnectionCap(kind: "mcp" | "obsidian"): ConnectionCapState {
  const { data: billing } = useBillingStatus()
  if (!billing) return { isLoading: true, atCap: false, limit: null, current: 0 }

  const limit =
    kind === "obsidian"
      ? billing.caps.obsidian_connections
      : billing.caps.mcp_connections
  const current = billing.current_connections?.[kind] ?? 0
  const atCap = typeof limit === "number" && limit > 0 && current >= limit

  return { isLoading: false, atCap, limit, current }
}
