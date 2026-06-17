import { describe, it, expect, vi, beforeEach } from "vitest"
import { api, setUpgradeHandler, LimitExceededError, ApiError } from "./client"

describe("api client 402 handling", () => {
  beforeEach(() => {
    setUpgradeHandler(null)
    vi.restoreAllMocks()
  })

  it("calls upgradeHandler and throws LimitExceededError on 402", async () => {
    const handler = vi.fn()
    setUpgradeHandler(handler)

    globalThis.fetch = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          error: "limit_exceeded",
          reason: "notes_cap_exceeded",
          limit_key: "notes_cap",
          limit: 10000,
          current: 10000,
          upgrade_url: "https://app.engram.page/settings/billing",
        }),
        { status: 402, headers: { "Content-Type": "application/json" } },
      ),
    )

    await expect(api.post("/notes", {})).rejects.toMatchObject({
      name: "LimitExceededError",
      reason: "notes_cap_exceeded",
      limitKey: "notes_cap",
      limit: 10000,
      current: 10000,
      upgradeUrl: "https://app.engram.page/settings/billing",
    })
    expect(handler).toHaveBeenCalledWith("notes_cap_exceeded")
  })

  it("does not crash when no upgradeHandler is registered", async () => {
    setUpgradeHandler(null)

    globalThis.fetch = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          error: "limit_exceeded",
          reason: "vaults_cap_exceeded",
        }),
        { status: 402, headers: { "Content-Type": "application/json" } },
      ),
    )

    await expect(api.post("/vaults", {})).rejects.toBeInstanceOf(
      LimitExceededError,
    )
  })

  it("LimitExceededError carries null fields when body is empty", async () => {
    globalThis.fetch = vi.fn().mockResolvedValue(
      new Response("not-json", { status: 402 }),
    )

    try {
      await api.get("/anything")
      expect.fail("should have thrown")
    } catch (e) {
      expect(e).toBeInstanceOf(LimitExceededError)
      const err = e as LimitExceededError
      expect(err.reason).toBe("unknown")
      expect(err.limitKey).toBeNull()
      expect(err.limit).toBeNull()
      expect(err.current).toBeNull()
      expect(err.upgradeUrl).toBeNull()
    }
  })

  it("non-402 errors still throw ApiError", async () => {
    globalThis.fetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ error: "boom" }), { status: 500 }),
    )

    await expect(api.get("/x")).rejects.toBeInstanceOf(ApiError)
  })

  it("sends an X-Device-Id header on every request", async () => {
    const fetchMock = vi
      .fn()
      .mockResolvedValue(new Response("{}", { status: 200 }))
    globalThis.fetch = fetchMock

    await api.get("/anything")

    const init = fetchMock.mock.calls[0][1] as RequestInit
    const headers = init.headers as Headers
    expect(headers.get("X-Device-Id")).toMatch(/^[0-9a-f-]{36}$/)
  })
})
