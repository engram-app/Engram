//! Engram's pure-Rust core: the code the backend NIF (native/engram_native)
//! shares with clients that run it as wasm32. No rustler, no randomness of
//! its own (callers draw nonces), no unsafe.
#![cfg_attr(not(test), forbid(unsafe_code))]

pub mod envelope;

#[cfg(test)]
mod peak;
