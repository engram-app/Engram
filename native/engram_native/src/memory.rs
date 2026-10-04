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
use rustler::EnifAllocator;
use std::alloc::{GlobalAlloc, Layout};
use std::cell::Cell;
use std::sync::atomic::{AtomicIsize, Ordering::Relaxed};

pub struct Counting;

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
        let ptr = EnifAllocator.alloc(layout);
        if !ptr.is_null() {
            track(layout.size() as isize);
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        EnifAllocator.dealloc(ptr, layout);
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
