import { describe, it, expect } from "vitest";
import { loadVersion, sha256Hex } from "./load";
describe("sha256Hex", () => {
  it("matches canonical lowercase-hex sha256 of UTF-8 bytes", async () => {
    expect(await sha256Hex("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    expect(await sha256Hex("# Terms of Service\n")).toMatch(/^[0-9a-f]{64}$/);
  });
});

describe("loadVersion", () => {
  it("returns the bundled terms markdown", () => {
    expect(loadVersion("terms", "2026-05-19")).toMatch(/^# Terms of Service/);
  });

  it("throws for an unknown version", () => {
    expect(() => loadVersion("terms", "9999-99-99")).toThrow(/missing bundled/);
  });
});
