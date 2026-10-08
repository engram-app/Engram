//! Test-only: a counting allocator so tests can bound a call's peak heap,
//! as the NIF's memory.rs does in production. The only unsafe in the crate,
//! and it is compiled into tests alone.
use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

struct Counting;

#[global_allocator]
static ALLOCATOR: Counting = Counting;

thread_local! {
    static LIVE: Cell<isize> = const { Cell::new(0) };
    static PEAK: Cell<isize> = const { Cell::new(0) };
}

fn track(delta: isize) {
    let _ = LIVE.try_with(|live| {
        let now = live.get() + delta;
        live.set(now);
        let _ = PEAK.try_with(|peak| peak.set(peak.get().max(now)));
    });
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let ptr = System.alloc(layout);
        if !ptr.is_null() {
            track(layout.size() as isize);
        }
        ptr
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout);
        track(-(layout.size() as isize));
    }
}

/// `f`'s result and the peak bytes this thread allocated while it ran.
pub fn measured<T>(f: impl FnOnce() -> T) -> (T, usize) {
    let base = LIVE.with(|l| l.get());
    PEAK.with(|p| p.set(base));
    let out = f();
    (out, PEAK.with(|p| (p.get() - base).max(0) as usize))
}

#[test]
fn counts_this_threads_allocations() {
    let ((), peak) = measured(|| drop(Vec::<u8>::with_capacity(1 << 20)));
    assert!(peak >= 1 << 20);
}
