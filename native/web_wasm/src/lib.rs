//! `engram_core::frontmatter::split` for the web app. JS writes a note's
//! UTF-8 at `input_ptr()` (growing memory to fit), calls `fm_split(len)`,
//! and on 1 reads (block_start, block_end, body_start, add_newline) as four
//! u32s at `out_ptr()`. No allocator: the input lives past the heap base.
//! See frontend/src/crdt/frontmatter-fence.ts. Empty off wasm32, so the
//! workspace's host builds and lints skip it.
#![cfg(target_arch = "wasm32")]

use engram_core::frontmatter::split;

static mut OUT: [u32; 4] = [0; 4];

extern "C" {
    // Defined by wasm-ld: the end of static data and the stack.
    static __heap_base: u8;
}

/// Where JS writes the input.
#[no_mangle]
pub extern "C" fn input_ptr() -> *const u8 {
    &raw const __heap_base
}

/// Where `fm_split` writes its four results.
#[no_mangle]
pub extern "C" fn out_ptr() -> *const u32 {
    (&raw const OUT).cast()
}

/// Splits the `len` bytes at `input_ptr()`: 1 with the offsets at
/// `out_ptr()`, 0 for no frontmatter.
///
/// # Safety
/// `len` bytes from `input_ptr()` must be inside linear memory.
#[no_mangle]
pub unsafe extern "C" fn fm_split(len: usize) -> u32 {
    let s = core::slice::from_raw_parts(input_ptr(), len);
    match split(s) {
        None => 0,
        Some((bs, be, body, nl)) => {
            OUT = [bs as u32, be as u32, body as u32, nl as u32];
            1
        }
    }
}
