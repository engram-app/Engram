//! Exports engram_core's envelope seal and open over caller memory, so a
//! wasm32 link keeps every code path a client reaches (and drops nothing CI
//! should see). Not an API: the CI wasm step builds it and fails if the
//! module imports anything from its host.

use engram_core::envelope::{open, seal, Mode, Opened, NONCE};

/// Seals `len` bytes at `ptr` under a fixed key, opens the result, and
/// returns the opened length (or `usize::MAX` on error).
///
/// # Safety
/// `ptr` must point at `len` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn guard_roundtrip(ptr: *const u8, len: usize, zstd: bool) -> usize {
    let plain = std::slice::from_raw_parts(ptr, len);
    let key = [7u8; 32];
    let mode = if zstd { Mode::Auto } else { Mode::None };
    let alloc = |n| Some(vec![0u8; n]);
    let Ok((ct, nonce)) = seal(plain, &key, b"aad", mode, [1; NONCE], alloc) else {
        return usize::MAX;
    };
    match open(&ct, &nonce, &key, b"aad", alloc) {
        Ok(Opened::InPlace(buf, skip)) => buf.len() - skip,
        Ok(Opened::Inflated(v)) => v.len(),
        Err(_) => usize::MAX,
    }
}
