//! `Engram.Notes.Frontmatter.split/1`: where a note's leading YAML block
//! ends, as byte offsets, so the Elixir side slices sub-binaries instead of
//! copying a large body. The rule itself is `engram_core::frontmatter`.

pub use engram_core::frontmatter::{split, split_after_bom, Split};

/// The block (with its trailing newline) and the body, as strings.
pub fn parts(s: &str) -> (Option<String>, &str) {
    match split(s.as_bytes()) {
        None => (None, s),
        Some((bs, be, body, nl)) => {
            let mut block = s[bs..be].to_string();
            if nl {
                block.push('\n');
            }
            (Some(block), &s[body..])
        }
    }
}
