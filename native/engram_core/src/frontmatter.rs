//! The one frontmatter fence rule. The backend splits notes with it
//! (`Engram.Notes.Frontmatter.split/1`, the chunker, title/tags, links) and
//! the web app runs the same code as wasm32 (`native/web_wasm`). The shared
//! fixture table `fixtures/frontmatter_fence.json` is asserted by this
//! crate, the NIF tests and the web vitest, so the copies cannot drift.
//!
//! The rule, in Obsidian's terms (checked against app 1.12.7):
//! - Opens only at byte 0 on a line that is exactly `---`, LF or CRLF.
//!   Obsidian's `getFrontMatterInfo` (`/^---(\r?\n)/`) agrees.
//! - Closes on the first later line that is `---` plus optional spaces or
//!   tabs, LF, CRLF or end of text. `---foo`, `----` and `---` followed by
//!   other whitespace (U+180E) do not close. `getFrontMatterInfo` also
//!   rejects `---foo`; Obsidian's metadata cache accepts it, and is the
//!   lenient one on trailing blanks, so this sits between the two.
//! - `---` straight after the opening fence is an empty block.
//! - A BOM is not skipped here: the CRDT ingest must round-trip the bytes.
//!   Read-only derivations (chunks, title, tags, links) call
//!   [`split_after_bom`], as Obsidian's metadata cache strips a BOM first.
//!
//! Scans bytes, so invalid UTF-8 splits byte for byte; every fence byte is
//! ASCII, so on valid text each offset is a char boundary. Hand-written, no
//! `regex`: the wasm build stays a few KB.

/// (block_start, block_end, body_start, add_newline). The block is
/// `s[block_start..block_end]` plus "\n" when `add_newline`; None: no
/// frontmatter, the whole note is body.
pub type Split = Option<(usize, usize, usize, bool)>;

const BOM: &[u8] = "\u{FEFF}".as_bytes();

/// Length of an opening fence (`---\n` or `---\r\n`) at the start of `s`.
fn open_fence(s: &[u8]) -> Option<usize> {
    if s.starts_with(b"---\r\n") {
        Some(5)
    } else if s.starts_with(b"---\n") {
        Some(4)
    } else {
        None
    }
}

/// If `line` (from just after a `\n`) is a closing fence: the length it
/// consumes, its line ending included. `at_eof` when it ends the text.
fn close_fence(line: &[u8]) -> Option<(usize, bool)> {
    let rest = line.strip_prefix(b"---")?;
    let blanks = rest
        .iter()
        .take_while(|&&b| b == b' ' || b == b'\t')
        .count();
    let mut n = 3 + blanks;
    if line.get(n) == Some(&b'\r') {
        n += 1;
    }
    match line.get(n) {
        None => Some((n, true)),
        Some(b'\n') => Some((n + 1, false)),
        Some(_) => None,
    }
}

pub fn split(s: &[u8]) -> Split {
    let start = open_fence(s)?;
    // `get`, not indexing, here and below: no panic path, so the wasm
    // carries no panic formatting (half its size).
    let rest = s.get(start..)?;
    if let Some(n) = open_fence(rest) {
        return Some((start, start, start + n, false));
    }
    let mut at = 0;
    while let Some(nl) = rest.get(at..)?.iter().position(|&b| b == b'\n') {
        let line = at + nl + 1;
        if let Some((n, eof)) = close_fence(rest.get(line..)?) {
            let body = if eof { s.len() } else { start + line + n };
            return Some((start, start + line - 1, body, true));
        }
        at = line;
    }
    None
}

/// `split` after one leading UTF-8 BOM, offsets still into `s`.
pub fn split_after_bom(s: &[u8]) -> Split {
    let skip = if s.starts_with(BOM) { BOM.len() } else { 0 };
    split(s.get(skip..)?).map(|(bs, be, body, nl)| (bs + skip, be + skip, body + skip, nl))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(serde::Deserialize)]
    struct Case {
        name: String,
        input: String,
        block: Option<String>,
        body: String,
    }

    fn cases() -> Vec<Case> {
        serde_json::from_str(include_str!("../fixtures/frontmatter_fence.json")).unwrap()
    }

    fn parts(s: &str, split: Split) -> (Option<String>, &str) {
        match split {
            None => (None, s),
            Some((bs, be, body, nl)) => {
                let block = s[bs..be].to_string() + if nl { "\n" } else { "" };
                (Some(block), &s[body..])
            }
        }
    }

    #[test]
    fn the_shared_fixture_table() {
        for c in cases() {
            let got = parts(&c.input, split(c.input.as_bytes()));
            assert_eq!(got, (c.block.clone(), c.body.as_str()), "{}", c.name);
        }
    }

    #[test]
    fn after_a_bom_the_rule_is_the_same() {
        for c in cases() {
            let with = format!(
                "\u{FEFF}{}",
                c.input.strip_prefix('\u{FEFF}').unwrap_or(&c.input)
            );
            let plain = &with[3..];
            let (block, body) = parts(&with, split_after_bom(with.as_bytes()));
            let (want_block, want_body) = parts(plain, split(plain.as_bytes()));
            assert_eq!(block, want_block, "{}", c.name);
            // No frontmatter: the whole text (BOM included) is body.
            let want_body = if want_block.is_none() {
                &with
            } else {
                want_body
            };
            assert_eq!(body, want_body, "{}", c.name);
        }
    }

    #[test]
    fn invalid_utf8_splits_byte_for_byte() {
        let s = b"---\na: \xff\n---\nbody \xfe";
        assert_eq!(split(s), Some((4, 8, 13, true)));
    }
}
