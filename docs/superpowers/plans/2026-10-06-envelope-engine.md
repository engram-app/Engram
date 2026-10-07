# Envelope engine (Rust NIF) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace OpenSSL `:crypto` AES-256-GCM with one Rust NIF engine (RustCrypto `aes-gcm` + `zstd`) behind `Engram.Crypto.Envelope` for every caller, able to read the new versioned format, while still WRITING today's exact bytes (release R1 of #1872).

**Architecture:** `native/engram_native/src/envelope.rs` seals and opens in one call: an optional zstd pass and AES-GCM over one buffer. The nonce field carries the format: 12 bytes = format 0 (today's bytes, unchanged AAD), 13 bytes `<<1, nonce::12>>` = format 1 (AAD gets `"|f1"`, plaintext body is `<<codec, payload>>`, codec 0 raw / 1 zstd). `Envelope` keeps its public API; the compression mode is chosen from the AAD's `table:column` prefix by one policy function, so every caller, including DEK rotation and AAD rebind, gets the right mode with no per-site flag. In this PR the policy is switched off by config (`:envelope_compression`, default `false`), so writes stay format 0; PR 3 turns it on.

**Tech Stack:** Rust (rustler 0.38, aes-gcm 0.10, zstd 0.13, getrandom 0.2), Elixir. Mix via `mise exec --`.

**Spec:** Engram vault `50 Engineering/_Superpowers Specs/2026-10-06-envelope-engine-and-data-migrations-design.md`, sections 4, 7 (R1), 8, 10. Issue engram-app/Engram#1872.

## Global Constraints

- Worktree `/home/open-claw/documents/code-projects/engram/.worktrees/envelope-engine`, branch `feat/1872-envelope-engine`. Isolated test DB: `MIX_TEST_PARTITION=_env1872` (create + migrate it first).
- Every mix command via `mise exec --`. Cargo tests: `cd native/engram_native && cargo test --release`. Also `cargo fmt --check` and `cargo clippy --release -- -D warnings`.
- Format 0 output must be byte-compatible with `:crypto`: same ciphertext||tag for the same key, nonce, AAD and plaintext.
- Format 0 is the only format this PR writes (config `:envelope_compression` defaults to `false` in every env).
- `KeyProvider.Local`'s packed wrap blob (`<<version, alg, nonce::12, ct>>`) and anything else that packs the nonce at a fixed offset stays format 0 forever: their AADs are not in the compression policy.
- Empty plaintext is always format 0 (so `revisions.ex` `has_content?/1`'s `byte_size(ct) > tag_bytes()` stays true to its meaning).
- Never a size cap on input. Never a panic across the NIF boundary: malformed input returns `:error`.
- Follow `docs/context/native-nifs.md`: dirty variant above 16 KB, `Engram.Native.call/4` telemetry, peak + leak tests, no threads (no rayon), baseline x86-64 build.
- Commits: conventional, signed, each ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01Asw3J7d43tbFAKR8GrroSX`. No em dashes.

## Review Focus

1. A row written today (format 0, `:crypto`) must open after the swap, for every AAD shape including legacy `<<>>` AAD and wrapped DEKs. Pinned by the golden set (Task 1).
2. A 13-byte nonce field whose first byte is not a known format, a 12-byte nonce with format-1 bytes, or a format-1 row opened with the AAD without `"|f1"` must return `:error`, not garbage. Pinned in Task 2.
3. DEK rotation and AAD rebind re-encrypt through `Envelope`; with the policy ON they must write the column's mode, not silently downgrade. Pinned in Task 4.
4. Concurrent seals on many scheduler threads must not share a zstd context unsafely or leak: thread-local contexts, leak test warmed per scheduler. Pinned in Task 3.
5. A key that is not 32 bytes, a nil nonce, or a non-binary must not crash the node: `Envelope` guards stay, NIF returns `:error` / raises `ArgumentError` only where `:crypto` did. Pinned in Task 3.

---

### Task 1: Golden set from today's `:crypto` (before any swap)

**Files:**
- Create: `test/support/gen_envelope_golden.exs` (one-off generator, kept for regeneration only under a version bump)
- Create: `test/support/fixtures/envelope_golden.json`
- Create: `test/engram/crypto/envelope_golden_test.exs`

- [ ] **Step 1:** Write the generator. It uses the CURRENT `Engram.Crypto.Envelope` (still `:crypto`) and a fresh random 32-byte key, and emits base64 JSON cases: `%{key, aad, plaintext, nonce, ct}` for AADs `""` (legacy), `Crypto.aad_for_row(:notes, :content, uuid)`, `:notes, :crdt_state`, `:vault_index_states, :state`, `:vault_index_update_log, :update`, `:attachments, :content`, `:attachments, :path`, `:note_revisions, :content`, `Crypto.aad_for_qdrant(...)`, `Crypto.aad_for_wrapped_dek(uuid)`; plaintexts: empty, 1 byte, 100 bytes of markdown, 20 KB of markdown (repeat a docs/context file), 3 KB of random bytes (binary CRDT-like). Run it: `MIX_ENV=test mise exec -- mix run --no-start test/support/gen_envelope_golden.exs > test/support/fixtures/envelope_golden.json`.
- [ ] **Step 2:** Test:

```elixir
defmodule Engram.Crypto.EnvelopeGoldenTest do
  use ExUnit.Case, async: true
  alias Engram.Crypto.Envelope

  @golden "test/support/fixtures/envelope_golden.json" |> File.read!() |> Jason.decode!()

  test "every ciphertext written by the :crypto envelope still opens" do
    for c <- @golden do
      [key, aad, plain, nonce, ct] = Enum.map(~w(key aad plaintext nonce ct), &Base.decode64!(c[&1]))
      assert Envelope.decrypt(ct, nonce, key, aad) == {:ok, plain}, inspect(c["aad"])
    end
  end

  end
end
```

The byte-identity check against `:crypto` comes in Task 3. The golden test passes today (`:crypto`) and is the guard for the swap.
- [ ] **Step 3:** `MIX_TEST_PARTITION=_env1872 MIX_ENV=test mise exec -- mix test test/engram/crypto/envelope_golden_test.exs` passes. Commit `test(crypto): golden ciphertexts from the :crypto envelope`.

### Task 2: The Rust engine (`envelope.rs`), cargo-tested

**Files:**
- Modify: `native/engram_native/Cargo.toml` (add `aes-gcm = { version = "0.10", features = ["zeroize"] }`, `zstd = "0.13"`, `getrandom = "0.2"`)
- Create: `native/engram_native/src/envelope.rs`
- Modify: `native/engram_native/src/lib.rs` (`mod envelope;`)

**Interfaces (Rust):**
- `pub enum Mode { None, Zstd, Auto }`
- `pub fn seal(plain: &[u8], key: &[u8], aad: &[u8], mode: Mode) -> Result<(Vec<u8>, Vec<u8>), ()>` returns `(ct_with_tag, nonce_field)`; `Err(())` only for a key that is not 32 bytes or an RNG failure.
- `pub fn seal_with_nonce(plain, key, aad, mode, nonce: [u8; 12]) -> Result<(Vec<u8>, Vec<u8>), ()>` (test hook; `seal` calls it with a fresh nonce).
- `pub fn open(ct_with_tag: &[u8], nonce_field: &[u8], key: &[u8], aad: &[u8]) -> Result<Vec<u8>, ()>`

- [ ] **Step 1: Write the module with its tests.**

```rust
//! The envelope engine: optional zstd + AES-256-GCM in one call.
//!
//! Format 0: 12-byte nonce field, AAD as given, body = plaintext. Byte for
//! byte what OpenSSL `:crypto` wrote before this engine.
//! Format 1: nonce field `<<1, nonce::12>>`, AAD = caller AAD ++ "|f1" (so
//! the format byte is authenticated), body = `<<codec, payload>>` where
//! codec 0 = raw, 1 = one zstd frame (content size + checksum on).
use aes_gcm::aead::{AeadInPlace, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce, Tag};
use std::cell::RefCell;

pub const TAG: usize = 16;
const NONCE: usize = 12;
const FORMAT_1: u8 = 1;
const CODEC_RAW: u8 = 0;
const CODEC_ZSTD: u8 = 1;
const LEVEL: i32 = 3;
// :auto compresses a sample first; incompressible media skips the full pass.
const SAMPLE: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Mode {
    None,
    Zstd,
    Auto,
}

thread_local! {
    // One context per scheduler thread: creating one costs ~0.3 ms (spike).
    static CCTX: RefCell<Option<zstd::bulk::Compressor<'static>>> = const { RefCell::new(None) };
    static DCTX: RefCell<Option<zstd::bulk::Decompressor<'static>>> = const { RefCell::new(None) };
}

fn compress(data: &[u8]) -> Option<Vec<u8>> {
    CCTX.with(|c| {
        let mut c = c.borrow_mut();
        if c.is_none() {
            let mut z = zstd::bulk::Compressor::new(LEVEL).ok()?;
            z.include_checksum(true).ok()?;
            z.include_contentsize(true).ok()?;
            *c = Some(z);
        }
        c.as_mut()?.compress(data).ok()
    })
}

fn decompress(frame: &[u8]) -> Option<Vec<u8>> {
    let size = zstd::zstd_safe::get_frame_content_size(frame).ok()??;
    DCTX.with(|d| {
        let mut d = d.borrow_mut();
        if d.is_none() {
            *d = Some(zstd::bulk::Decompressor::new().ok()?);
        }
        d.as_mut()?.decompress(frame, size as usize).ok()
    })
}

fn cipher(key: &[u8]) -> Result<Aes256Gcm, ()> {
    Aes256Gcm::new_from_slice(key).map_err(|_| ())
}

fn f1_aad(aad: &[u8]) -> Vec<u8> {
    let mut a = Vec::with_capacity(aad.len() + 3);
    a.extend_from_slice(aad);
    a.extend_from_slice(b"|f1");
    a
}

pub fn seal(plain: &[u8], key: &[u8], aad: &[u8], mode: Mode) -> Result<(Vec<u8>, Vec<u8>), ()> {
    let mut nonce = [0u8; NONCE];
    getrandom::getrandom(&mut nonce).map_err(|_| ())?;
    seal_with_nonce(plain, key, aad, mode, nonce)
}

pub fn seal_with_nonce(
    plain: &[u8],
    key: &[u8],
    aad: &[u8],
    mode: Mode,
    nonce: [u8; NONCE],
) -> Result<(Vec<u8>, Vec<u8>), ()> {
    let c = cipher(key)?;
    // Empty input stays format 0: revisions' has_content? reads "ct is only a tag".
    if mode == Mode::None || plain.is_empty() {
        let mut buf = Vec::with_capacity(plain.len() + TAG);
        buf.extend_from_slice(plain);
        let tag = c
            .encrypt_in_place_detached(Nonce::from_slice(&nonce), aad, &mut buf)
            .map_err(|_| ())?;
        buf.extend_from_slice(&tag);
        return Ok((buf, nonce.to_vec()));
    }

    let try_zstd = match mode {
        Mode::Auto => {
            let sample = &plain[..plain.len().min(SAMPLE)];
            matches!(compress(sample), Some(z) if z.len() * 10 <= sample.len() * 9)
        }
        _ => true,
    };
    let (codec, payload) = match try_zstd.then(|| compress(plain)).flatten() {
        Some(z) if z.len() < plain.len() => (CODEC_ZSTD, z),
        _ => (CODEC_RAW, plain.to_vec()),
    };

    let mut buf = Vec::with_capacity(1 + payload.len() + TAG);
    buf.push(codec);
    buf.extend_from_slice(&payload);
    let tag = c
        .encrypt_in_place_detached(Nonce::from_slice(&nonce), &f1_aad(aad), &mut buf)
        .map_err(|_| ())?;
    buf.extend_from_slice(&tag);

    let mut field = Vec::with_capacity(1 + NONCE);
    field.push(FORMAT_1);
    field.extend_from_slice(&nonce);
    Ok((buf, field))
}

pub fn open(ct: &[u8], nonce_field: &[u8], key: &[u8], aad: &[u8]) -> Result<Vec<u8>, ()> {
    let c = cipher(key)?;
    if ct.len() < TAG {
        return Err(());
    }
    let (body, tag) = ct.split_at(ct.len() - TAG);
    let mut buf = body.to_vec();
    match nonce_field {
        [n @ ..] if n.len() == NONCE => {
            c.decrypt_in_place_detached(Nonce::from_slice(n), aad, &mut buf, Tag::from_slice(tag))
                .map_err(|_| ())?;
            Ok(buf)
        }
        [FORMAT_1, n @ ..] if n.len() == NONCE => {
            c.decrypt_in_place_detached(Nonce::from_slice(n), &f1_aad(aad), &mut buf, Tag::from_slice(tag))
                .map_err(|_| ())?;
            match buf.split_first() {
                Some((&CODEC_RAW, rest)) => Ok(rest.to_vec()),
                Some((&CODEC_ZSTD, rest)) => decompress(rest).ok_or(()),
                _ => Err(()),
            }
        }
        _ => Err(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const K: [u8; 32] = [7; 32];

    fn rt(plain: &[u8], mode: Mode) -> (Vec<u8>, Vec<u8>) {
        let (ct, n) = seal(plain, &K, b"notes:content:x", mode).unwrap();
        assert_eq!(open(&ct, &n, &K, b"notes:content:x").unwrap(), plain);
        (ct, n)
    }

    #[test]
    fn round_trips_every_mode_and_size() {
        let text = "Some markdown with [[links]] and #tags.\n".repeat(5_000);
        for p in [&b""[..], b"x", text.as_bytes()] {
            for m in [Mode::None, Mode::Zstd, Mode::Auto] {
                rt(p, m);
            }
        }
    }

    #[test]
    fn formats() {
        let text = "repeat ".repeat(1_000);
        assert_eq!(rt(text.as_bytes(), Mode::None).1.len(), 12);
        assert_eq!(rt(b"", Mode::Zstd).1.len(), 12);
        let (ct, n) = rt(text.as_bytes(), Mode::Zstd);
        assert_eq!(n.len(), 13);
        assert!(ct.len() < text.len());
    }

    #[test]
    fn incompressible_auto_stays_raw_but_versioned() {
        let mut noise = vec![0u8; 200_000];
        getrandom::getrandom(&mut noise).unwrap();
        let (ct, n) = rt(&noise, Mode::Auto);
        assert_eq!(n[0], 1);
        assert_eq!(ct.len(), noise.len() + 1 + TAG);
    }

    #[test]
    fn tamper_fails_closed() {
        let text = "abc ".repeat(500);
        let (ct, n) = seal(text.as_bytes(), &K, b"a", Mode::Zstd).unwrap();
        let mut bad_format = n.clone();
        bad_format[0] = 2;
        assert!(open(&ct, &bad_format, &K, b"a").is_err());
        assert!(open(&ct, &n[1..], &K, b"a").is_err()); // format byte dropped
        assert!(open(&ct, &n, &K, b"b").is_err()); // wrong AAD
        assert!(open(&ct, &n, &[8; 32], b"a").is_err()); // wrong key
        let mut flipped = ct.clone();
        flipped[0] ^= 1;
        assert!(open(&flipped, &n, &K, b"a").is_err());
        assert!(open(&ct[..10], &n, &K, b"a").is_err());
        assert!(open(&ct, &n, &K[..31], b"a").is_err());
    }

    #[test]
    fn format_zero_matches_known_answer() {
        // NIST-style KAT: all-zero key and nonce, empty plaintext and AAD.
        let (ct, _) = seal_with_nonce(b"", &[0; 32], b"", Mode::None, [0; 12]).unwrap();
        assert_eq!(hex(&ct), "530f8afbc74536b9a963b4f1c4cb738b");
    }

    fn hex(b: &[u8]) -> String {
        b.iter().map(|x| format!("{x:02x}")).collect()
    }

    #[test]
    fn open_never_panics_on_garbage() {
        let mut seed = 1u64;
        for _ in 0..20_000 {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            let len = (seed % 64) as usize;
            let junk: Vec<u8> = (0..len).map(|i| (seed >> (i % 8)) as u8).collect();
            let nlen = [0usize, 11, 12, 13, 14][(seed % 5) as usize];
            let _ = open(&junk, &junk[..nlen.min(junk.len())], &K, b"a");
        }
    }
}
```

The KAT hex above is the published AES-256-GCM tag for an all-zero key, all-zero 96-bit IV, empty plaintext and empty AAD (`530f8afbc74536b9a963b4f1c4cb738b`). If it does not match, recheck it against `:crypto.crypto_one_time_aead(:aes_256_gcm, <<0::256>>, <<0::96>>, "", "", true)` in iex and use that value (it must equal OpenSSL's).

- [ ] **Step 2:** `cargo test --release envelope`, `cargo fmt --check`, `cargo clippy --release -- -D warnings`. Fix any clippy findings in the module (e.g. the slice pattern may need `n if n.len() == NONCE` rewritten as explicit length matches if clippy or the borrow checker objects; keep behaviour identical).
- [ ] **Step 3:** Commit `feat(native): envelope engine (zstd + aes-gcm)`.

### Task 3: NIF entry points, `Engram.Native` wrapper, `Envelope` on the engine

**Files:**
- Modify: `native/engram_native/src/lib.rs` (NIFs)
- Modify: `lib/engram/native.ex`
- Modify: `lib/engram/crypto/envelope.ex`
- Create: `test/support/crypto_oracle.ex` (the old `:crypto` envelope, test-only)
- Create: `test/engram/native/envelope_test.exs`
- Modify: `test/engram/crypto/envelope_test.exs` (keep every case; the 12-byte nonce assertion stays true for format 0)

**Interfaces:**
- Rust NIFs (normal + `_dirty_nif`): `envelope_seal_nif(plain: Binary, key: Binary, aad: Binary, mode: Atom) -> ((Binary, Binary) | :error, peak)`; `envelope_open_nif(ct, nonce, key, aad) -> (Binary | :error, peak)`; test hook `envelope_seal_with_nonce_nif(plain, key, aad, mode, nonce)` (normal scheduler only, `@doc false`).
- `Engram.Native.envelope_seal(plain, key, aad, mode) :: {ct, nonce}` (raises `ArgumentError` on a bad key, as `:crypto` did); `Engram.Native.envelope_open(ct, nonce, key, aad) :: {:ok, plain} | :error`.
- `Engram.Crypto.Envelope`: unchanged signatures. `encrypt/3` seals with `mode_for(aad)`; `decrypt/4` opens any format. New `@doc false` `mode_for/1` and `compression_policy/1`.

- [ ] **Step 1: Failing tests** in `test/engram/native/envelope_test.exs`:
  - format-0 seal with a fixed nonce equals `CryptoOracle.encrypt_with_nonce/4` byte for byte (StreamData, 500 runs, plaintext 0..40 KB, random AAD);
  - oracle-sealed (`:crypto`) ciphertext opens with the engine, and engine format-0 opens with the oracle (StreamData);
  - format-1 round trip for `:zstd` and `:auto` (call `Native.envelope_seal(..., :zstd)` directly; the policy is off);
  - tamper cases as in the Rust test, through `Envelope.decrypt/4`;
  - inputs over 16 KB run dirty (telemetry metadata `dirty: true`), the inline and dirty variants agree;
  - peak bound (`peak <= 3 * byte_size(plain) + 256 * 1024` for a 2 MB input) and `Engram.NativeLeak.assert_no_leak/1` over seal+open in all three modes (warm-up per scheduler covers the thread-local zstd contexts);
  - bad key size raises `ArgumentError` from `Envelope.encrypt` (as today, via the `<<_::256>>` guard) and `decrypt` returns `:error`.
- [ ] **Step 2:** Run them; they fail (functions undefined).
- [ ] **Step 3:** Implement. NIF layer copies `Vec` outputs into `NewBinary` (one memcpy), maps `Err(())` to `:error`, wraps with `memory::begin/peak_since`. `Engram.Native` gets `@inline_max` routing like `hmac_hex_many/3`. `Envelope`:

```elixir
  @policy [
    {"notes:content:", :zstd},
    {"notes:crdt_state:", :zstd},
    {"vault_index_states:state:", :zstd},
    {"vault_index_update_log:update:", :zstd},
    {"note_revisions:content:", :zstd},
    {"attachments:content:", :auto}
  ]

  @doc false
  # The compression mode for a ciphertext, from its AAD's table:column. One
  # place decides, so DEK rotation and AAD rebind re-encrypt with the same
  # mode as the original write. Off until #1872's R2 (config).
  def mode_for(aad) do
    if Application.get_env(:engram, :envelope_compression, false),
      do: compression_policy(aad),
      else: :none
  end

  @doc false
  def compression_policy(aad) do
    Enum.find_value(@policy, :none, fn {prefix, mode} ->
      if String.starts_with?(aad, prefix), do: mode
    end)
  end
```

  `encrypt(plaintext, dek, aad)` -> `Engram.Native.envelope_seal(plaintext, dek, aad, mode_for(aad))`. `decrypt(ct, nonce, dek, aad)` guards `is_binary(ct) and is_binary(nonce) and is_binary(aad)` and returns `Engram.Native.envelope_open(...)`; keep the `<<_::256>>` dek guard and the catch-all `:error` clause. Update the moduledoc: formats, policy, "off until R2". Remove every `:crypto.crypto_one_time_aead` from `lib/`.
- [ ] **Step 4:** Tests pass: the new file, `test/engram/crypto/`, the golden test, and every test file that calls `Envelope` (`grep -rl "Envelope\." test/ | xargs`).
- [ ] **Step 5:** Commit `feat(crypto): Envelope runs on the Rust engine (writes format 0)`.

### Task 4: Policy coverage across rotation and rebind (policy forced ON in tests)

**Files:**
- Test: `test/engram/crypto/envelope_policy_test.exs`

- [ ] **Step 1:** Tests, with `Application.put_env(:engram, :envelope_compression, true)` in setup and restored `on_exit` (file `async: false`):
  - `compression_policy/1` table: each prefix maps to its mode; `""`, `"dek:v1:..."`, `"qdrant:..."`, `"notes:title:..."`, `"attachments:path:..."` map to `:none`.
  - A note written with the policy on stores a 13-byte `content_nonce` and `crdt_state_nonce` (go through the public write path, e.g. `Notes.upsert_note/4` with a fixture user and DEK); its title nonce stays 12 bytes.
  - `UserDekRotation` over that user: afterwards content and crdt_state nonces are still 13 bytes and decrypt (rotation re-encrypts through `Envelope.encrypt/3`, so `mode_for/1` re-applies the policy). Use the existing rotation test helpers (`test/engram/crypto/user_dek_rotation_test.exs`).
  - `KeyProvider.Local` wrap blob is unchanged in size (62 bytes) with the policy on.
- [ ] **Step 2:** Run; fix only real defects (expected: none, since the policy keys off the AAD). Commit `test(crypto): compression policy follows the column through rotation`.

### Task 5: Benchmark, docs, gates

**Files:**
- Modify: `docs/context/native-nifs.md` (new "Envelope engine" section + table)
- Modify: `docs/context/encryption-operations.md` (an "Envelope formats" section: format 0/1, the `"|f1"` AAD suffix, codec byte, the policy table, R1/R2)

- [ ] **Step 1:** Benchmark script in the scratchpad (not committed): best of 5, sizes 2 KB / 10 KB / 100 KB / 1 MB of markdown; columns: `CryptoOracle` encrypt and decrypt, engine `:none` seal/open, engine `:zstd` seal/open, zstd ratio. Run with nothing else on the box if possible; note the load average.
- [ ] **Step 2:** Write the table and findings into `native-nifs.md`; write the formats section into `encryption-operations.md` (no em dashes).
- [ ] **Step 3:** Gates: `mise exec -- mix format --check-formatted`, `MIX_ENV=test mise exec -- mix credo --strict`, `MIX_ENV=test mise exec -- mix compile --warnings-as-errors`, `mise exec -- mix sobelow --exit low --skip`, `mise exec -- mix dialyzer`, cargo fmt/clippy/test, and the full suite once on `_env1872` with nothing else using it.
- [ ] **Step 4:** Commit `docs: envelope engine formats and benchmark`.
