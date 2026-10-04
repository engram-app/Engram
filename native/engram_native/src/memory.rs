//! NIF memory standard, part 1: every Rust allocation goes through the BEAM
//! (`enif_alloc`, so `:erlang.memory(:system)` and recon_alloc see it), and is
//! counted twice on the way:
//!
//! * `LIVE` — process-wide live bytes, for `Engram.Native.live_bytes/0` and
//!   leak tests.
//! * a thread-local live/peak pair. A dirty-scheduler NIF runs start to finish
//!   on ONE OS thread, so resetting the peak on entry and reading it on exit
//!   gives that call's native peak, the analogue of a process's heap high-water
//!   mark. It is only exact for NIFs that do not spawn threads; ours must not.
//!
//! Never a hard limit that returns null: an allocation failure aborts the
//! whole node, and catch_unwind cannot stop it. Bound memory by design and
//! prove it with the peak instead (test/engram/native).
use std::alloc::{GlobalAlloc, Layout};
use std::cell::Cell;
use std::sync::atomic::{AtomicIsize, Ordering::Relaxed};

pub struct Counting;

// `enif_alloc` only exists inside a running BEAM; `cargo test` counts over the
// system allocator instead, so the counting itself is under test too.
#[cfg(not(test))]
const INNER: rustler::EnifAllocator = rustler::EnifAllocator;
#[cfg(test)]
const INNER: std::alloc::System = std::alloc::System;

static LIVE: AtomicIsize = AtomicIsize::new(0);

thread_local! {
    // `const` init: no lazy allocation, so touching these inside the
    // allocator cannot recurse into it.
    static T_LIVE: Cell<isize> = const { Cell::new(0) };
    static T_PEAK: Cell<isize> = const { Cell::new(0) };
}

fn track(delta: isize) {
    LIVE.fetch_add(delta, Relaxed);
    // `try_with`: allocations during thread teardown must not panic.
    let _ = T_LIVE.try_with(|live| {
        let now = live.get() + delta;
        live.set(now);
        let _ = T_PEAK.try_with(|peak| {
            if now > peak.get() {
                peak.set(now)
            }
        });
    });
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = INNER.alloc(layout);
        if !ptr.is_null() {
            track(layout.size() as isize);
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        INNER.dealloc(ptr, layout);
        track(-(layout.size() as isize));
    }
    // `realloc` keeps the default (alloc + copy + dealloc through the two
    // methods above), so growth is counted. EnifAllocator has no realloc of
    // its own, so size buffers with `with_capacity`.
}

/// Start measuring a call on this thread; returns the baseline.
pub fn begin() -> isize {
    let base = T_LIVE.with(|l| l.get());
    T_PEAK.with(|p| p.set(base));
    base
}

/// Peak bytes allocated above `base` since `begin`.
pub fn peak_since(base: isize) -> usize {
    T_PEAK.with(|p| (p.get() - base).max(0) as usize)
}

pub fn live_bytes() -> isize {
    LIVE.load(Relaxed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn peak_counts_this_threads_allocations_and_live_returns_to_base() {
        let base = begin();
        let v: Vec<u8> = Vec::with_capacity(1 << 20);
        drop(v);
        assert!(peak_since(base) >= 1 << 20);
        // Other test threads allocate concurrently; only this thread's
        // counter is exact.
        assert_eq!(T_LIVE.with(|l| l.get()), base);
    }
}
