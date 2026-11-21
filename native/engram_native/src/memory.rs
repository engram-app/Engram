//! NIF memory standard, part 1: every Rust allocation goes through the BEAM
//! (`enif_alloc`, so `:erlang.memory(:system)` and recon_alloc see it), and is
//! counted twice on the way:
//!
//! * `LIVE` — process-wide live bytes, for `Engram.Native.live_bytes/0` and
//!   leak tests.
//! * a thread-local live/peak pair. A dirty-scheduler NIF runs start to finish
//!   on ONE OS thread, so resetting the peak on entry and reading it on exit
//!   gives that call's native peak, the analogue of a process's heap high-water
//!   mark. Work handed to the keyword encoder's worker pool (lib.rs
//!   `encode_parallel`) is measured on each worker and added to the caller's
//!   peak; any other NIF that used threads would have to do the same.
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

    /// `enif_realloc` (grows in place when it can, no copy through Rust),
    /// counted as the size change. EnifAllocator stores a header in front of
    /// a block aligned past 8, which `enif_realloc` would not move, so those
    /// keep the default: alloc + copy + dealloc through the methods above.
    /// The peak counts logical bytes: a moving realloc's brief old + new
    /// overlap happens inside the BEAM allocator and is not added.
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if layout.align() > MAX_ALIGN {
            let new = self.alloc(Layout::from_size_align_unchecked(new_size, layout.align()));
            if !new.is_null() {
                std::ptr::copy_nonoverlapping(ptr, new, layout.size().min(new_size));
                self.dealloc(ptr, layout);
            }
            return new;
        }
        let new = inner_realloc(ptr, layout, new_size);
        if !new.is_null() {
            track(new_size as isize - layout.size() as isize);
        }
        new
    }
}

/// The alignment `enif_alloc` guarantees (rustler's EnifAllocator MAX_ALIGN).
const MAX_ALIGN: usize = 8;

#[cfg(not(test))]
unsafe fn inner_realloc(ptr: *mut u8, _layout: Layout, new_size: usize) -> *mut u8 {
    rustler::sys::enif_realloc(ptr.cast(), new_size).cast()
}

#[cfg(test)]
unsafe fn inner_realloc(ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
    INNER.realloc(ptr, layout, new_size)
}

/// `f`'s result and the peak bytes this thread allocated while it ran,
/// above what it held live when `f` started.
pub fn measured<T>(f: impl FnOnce() -> T) -> (T, usize) {
    let base = T_LIVE.with(|l| l.get());
    T_PEAK.with(|p| p.set(base));
    let out = f();
    (out, T_PEAK.with(|p| (p.get() - base).max(0) as usize))
}

pub fn live_bytes() -> isize {
    LIVE.load(Relaxed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn peak_counts_this_threads_allocations_and_live_returns_to_base() {
        let base = T_LIVE.with(|l| l.get());
        let ((), peak) = measured(|| drop(Vec::<u8>::with_capacity(1 << 20)));
        assert!(peak >= 1 << 20);
        // Other test threads allocate concurrently; only this thread's
        // counter is exact.
        assert_eq!(T_LIVE.with(|l| l.get()), base);
    }

    fn here() -> isize {
        T_LIVE.with(|l| l.get())
    }

    // Growth through `realloc` counts the size change once: the peak of a
    // vector grown to capacity C is C, not C plus the block it moved from.
    #[test]
    fn realloc_growth_and_shrink_are_counted_once() {
        let base = here();
        let ((), peak) = measured(|| {
            let mut v = Vec::<u8>::with_capacity(1);
            for i in 0..(1u32 << 20) {
                v.push(i as u8);
            }
            let cap = v.capacity() as isize;
            assert_eq!(here() - base, cap);
            v.truncate(10);
            v.shrink_to_fit();
            assert_eq!(here() - base, v.capacity() as isize);
        });
        assert_eq!(here(), base);
        assert_eq!(peak, 1 << 20);

        // Over-aligned blocks take the alloc + copy + dealloc path.
        #[derive(Clone, Copy)]
        #[repr(align(64))]
        struct Wide(u8);
        let ((), peak) = measured(|| {
            let mut v = vec![Wide(1); 4];
            v.extend(std::iter::repeat_n(Wide(2), 60));
            assert_eq!(here() - base, (v.capacity() * 64) as isize);
            assert!(v.iter().skip(4).all(|w| w.0 == 2) && v[0].0 == 1);
        });
        assert_eq!(here(), base);
        assert!(peak >= 64 * 64);
    }

    // A shared regex's cache pool moved caches between threads, so bytes one
    // thread allocated were freed on another and a peak grew with whatever
    // ran beside it (#2186). `re!` gives each thread a regex of its own.
    #[test]
    fn each_thread_searches_with_its_own_regex() {
        fn a() -> usize {
            let r: &regex::Regex = re!(r"a+");
            assert!(r.is_match("baa"));
            r as *const regex::Regex as usize
        }
        let here = a();
        assert_eq!(a(), here, "one regex per thread, not per call");
        let there = std::thread::spawn(a).join().unwrap();
        assert_ne!(there, here, "two threads share a regex and its cache pool");
    }
}
