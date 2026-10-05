//! `Engram.Notes.Frontmatter.split/1`: where a note's leading YAML block
//! ends. Byte offsets, not strings, so the Elixir side slices sub-binaries
//! instead of copying a large body. Scans bytes, as the Elixir regexes did:
//! invalid UTF-8 splits exactly as before, and every fence is ASCII, so on
//! valid text each offset is a char boundary.
use regex::bytes::Regex;
use std::sync::OnceLock;

/// (block_start, block_end, body_start, add_newline). The block is
/// `s[block_start..block_end]` plus "\n" when `add_newline`; None: no
/// frontmatter, the whole note is body.
pub type Split = Option<(usize, usize, usize, bool)>;

/// The opening fence only at byte 0, with either line ending.
fn open_fence(s: &[u8]) -> Option<usize> {
    if s.starts_with(b"---\r\n") {
        Some(5)
    } else if s.starts_with(b"---\n") {
        Some(4)
    } else {
        None
    }
}

pub fn split(s: &[u8]) -> Split {
    static LINE: OnceLock<Regex> = OnceLock::new();
    static EOF: OnceLock<Regex> = OnceLock::new();
    let start = open_fence(s)?;
    let rest = &s[start..];
    // `---` straight after the opening fence: an empty block.
    if let Some(n) = open_fence(rest) {
        return Some((start, start, start + n, false));
    }
    // A closing fence line (trailing blanks and CR allowed), else one at EOF.
    let line = LINE.get_or_init(|| Regex::new(r"\n---[ \t]*\r?\n").unwrap());
    if let Some(m) = line.find(rest) {
        return Some((start, start + m.start(), start + m.end(), true));
    }
    let eof = EOF.get_or_init(|| Regex::new(r"\n---[ \t]*\r?\z").unwrap());
    eof.find(rest)
        .map(|m| (start, start + m.start(), s.len(), true))
}

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
