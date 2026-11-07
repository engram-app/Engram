//! The diffs behind `CrdtBridge`: `diff` is the single span (longest common
//! codepoint prefix and suffix) `diff_into_text/2` applies; `hunks` is the
//! multi-hunk diff `diff_hunks_into_text/2` applies for `Notes.CrdtWrite`.

use similar::{capture_diff_slices_deadline, Algorithm, DiffOp};
use std::time::{Duration, Instant};

/// `(prefix_u16, delete_u16, insert_start, insert_len)`. The first two are
/// UTF-16 units into `cur` (the doc is `offset_kind: :utf16`); the insert is
/// a byte range of `inc`, so Elixir slices it with `binary_part` and nothing
/// is copied. The suffix never overlaps the prefix. Allocates nothing;
/// linear in the inputs.
pub fn diff(cur: &str, inc: &str) -> (usize, usize, usize, usize) {
    let (c, i) = (cur.as_bytes(), inc.as_bytes());
    let (p, s) = trim(cur, inc);

    (
        utf16_len(&c[..p]),
        utf16_len(&c[p..c.len() - s]),
        p,
        i.len() - s - p,
    )
}

// Common prefix and suffix, in bytes, both on codepoint boundaries of both
// strings and never overlapping.
fn trim(cur: &str, inc: &str) -> (usize, usize) {
    let (c, i) = (cur.as_bytes(), inc.as_bytes());

    // Equal bytes up to a boundary in both are equal codepoints (UTF-8 is
    // self-synchronising), so back a byte match off to the last boundary.
    let mut p = c.iter().zip(i).take_while(|(a, b)| a == b).count();
    while !(cur.is_char_boundary(p) && inc.is_char_boundary(p)) {
        p -= 1;
    }

    let (cr, ir) = (&c[p..], &i[p..]);
    let mut s = cr
        .iter()
        .rev()
        .zip(ir.iter().rev())
        .take_while(|(a, b)| a == b)
        .count();
    while !(cur.is_char_boundary(c.len() - s) && inc.is_char_boundary(i.len() - s)) {
        s -= 1;
    }

    (p, s)
}

/// Bound on the line diff. Past it Myers returns a valid, coarser diff (a
/// larger replaced block), never a wrong one; the worst case is one hunk,
/// which is what `diff` gives.
const DEADLINE: Duration = Duration::from_millis(50);

/// The edits that turn `cur` into `inc`, ascending and non-overlapping:
/// `[(offset_u16, delete_u16, insert_start, insert_len)]`, offsets and
/// lengths into `cur` as in `diff`, inserts as byte ranges of `inc`. Apply
/// them last to first and the earlier offsets stay valid.
///
/// A line diff (Myers, bounded by `DEADLINE`) over the region the common
/// prefix and suffix leave, then each changed block trimmed to its own
/// changed span. So a rewrite that changes line 2 and line 200 leaves lines
/// 3 to 199 untouched, and a concurrent edit there survives it (the single
/// span deletes and re-inserts the whole range). The shape is
/// diff-match-patch's line mode, which Relay and the plugin apply.
pub fn hunks(cur: &str, inc: &str) -> Vec<(usize, usize, usize, usize)> {
    let (p, s) = trim(cur, inc);
    let (old, new) = (&cur[p..cur.len() - s], &inc[p..inc.len() - s]);

    // Byte ranges in `cur` and `inc`, ascending.
    let mut spans: Vec<(usize, usize, usize, usize)> = Vec::new();

    if !old.is_empty() || !new.is_empty() {
        let (old_lines, old_at) = lines(old, p);
        let (new_lines, new_at) = lines(new, p);
        let deadline = Instant::now() + DEADLINE;

        for op in capture_diff_slices_deadline(
            Algorithm::Myers,
            &old_lines,
            &new_lines,
            Some(deadline),
        ) {
            let (o, n) = (op.old_range(), op.new_range());
            if let DiffOp::Equal { .. } = op {
                continue;
            }
            let (ob, oe) = (old_at[o.start], old_at[o.end]);
            let (nb, ne) = (new_at[n.start], new_at[n.end]);
            // Trim the block to its changed span: one edit inside a line
            // stays one small edit.
            let (bp, bs) = trim(&cur[ob..oe], &inc[nb..ne]);
            spans.push((ob + bp, oe - bs, nb + bp, ne - bs));
        }
    }

    // One pass for every UTF-16 offset (each span's start and end in `cur`).
    let at: Vec<usize> = spans.iter().flat_map(|&(ob, oe, _, _)| [ob, oe]).collect();
    let u16 = utf16_offsets(cur, &at).expect("spans lie on char boundaries");

    spans
        .iter()
        .zip(u16.chunks(2))
        .map(|(&(_, _, nb, ne), o)| (o[0], o[1] - o[0], nb, ne - nb))
        .collect()
}

// `s` split after each newline, and the byte offset (plus `base`) of every
// line start with the end offset last, so line range `a..b` is bytes
// `at[a]..at[b]`.
fn lines(s: &str, base: usize) -> (Vec<&str>, Vec<usize>) {
    let lines: Vec<&str> = s.split_inclusive('\n').collect();
    let mut at = Vec::with_capacity(lines.len() + 1);
    let mut pos = base;
    at.push(pos);
    for l in &lines {
        pos += l.len();
        at.push(pos);
    }
    (lines, at)
}

/// UTF-16 offset of each byte offset in `at` (non-decreasing, each on a
/// char boundary of `s`), in one pass over `s`. None on a bad offset.
pub fn utf16_offsets(s: &str, at: &[usize]) -> Option<Vec<usize>> {
    let mut out = Vec::with_capacity(at.len());
    let (mut prev, mut units) = (0, 0);
    for &a in at {
        // is_char_boundary is false past the end.
        if a < prev || !s.is_char_boundary(a) {
            return None;
        }
        units += utf16_len(&s.as_bytes()[prev..a]);
        prev = a;
        out.push(units);
    }
    Some(out)
}

// Valid UTF-8: one unit per codepoint (every non-continuation byte), plus
// one more for each 4-byte lead (an astral codepoint, a surrogate pair).
fn utf16_len(b: &[u8]) -> usize {
    b.iter()
        .map(|&x| ((x & 0xC0) != 0x80) as usize + (x >= 0xF0) as usize)
        .sum()
}

#[cfg(test)]
mod tests {
    use super::{diff, hunks, utf16_offsets};

    #[test]
    fn offsets() {
        let s = "a📝é€b";
        assert_eq!(utf16_offsets(s, &[]), Some(vec![]));
        assert_eq!(
            utf16_offsets(s, &[0, 1, 5, 7, 10, 11]),
            Some(vec![0, 1, 3, 4, 5, 6])
        );
        assert_eq!(utf16_offsets(s, &[1, 1]), Some(vec![1, 1]));
        // Inside a codepoint, past the end, or going backwards.
        assert_eq!(utf16_offsets(s, &[2]), None);
        assert_eq!(utf16_offsets(s, &[12]), None);
        assert_eq!(utf16_offsets(s, &[5, 1]), None);
    }

    #[test]
    fn offsets_linear_time() {
        // One pass: a per-offset rescan from 0 would be ~10^10 steps here.
        let big = "prose 📝 ".repeat(1_000_000);
        let at: Vec<usize> = (0..big.len())
            .step_by(997)
            .filter(|&i| big.is_char_boundary(i))
            .collect();
        let t = std::time::Instant::now();
        assert_eq!(utf16_offsets(&big, &at).unwrap().len(), at.len());
        assert!(t.elapsed().as_secs() < 2);
    }

    fn run<'a>(cur: &str, inc: &'a str) -> (usize, usize, &'a str) {
        let (p, d, s, l) = diff(cur, inc);
        (p, d, &inc[s..s + l])
    }

    #[test]
    fn spans() {
        assert_eq!(run("", ""), (0, 0, ""));
        assert_eq!(run("abc", ""), (0, 3, ""));
        assert_eq!(run("aaa", "aaaa"), (3, 0, "a"));
        assert_eq!(run("aaaa", "aa"), (2, 2, ""));
        assert_eq!(run("é", "ê"), (0, 1, "ê"));
        assert_eq!(run("x📝y", "x🚀y"), (1, 2, "🚀"));
        assert_eq!(run("a📝b", "a📝c"), (3, 1, "c"));
    }

    #[test]
    fn linear_time() {
        // Quadratic would take minutes here; linear takes milliseconds.
        let big = "prose 📝 ".repeat(1_000_000);
        let inc = format!("x{big}y");
        let t = std::time::Instant::now();
        diff(&big, &inc);
        assert!(t.elapsed().as_secs() < 2);
    }

    // Applies `hunks` last to first, as `diff_hunks_into_text/2` does, on
    // UTF-16 units.
    fn apply(cur: &str, inc: &str) -> String {
        let mut units: Vec<u16> = cur.encode_utf16().collect();
        for (off, del, s, l) in hunks(cur, inc).into_iter().rev() {
            let ins: Vec<u16> = inc[s..s + l].encode_utf16().collect();
            units.splice(off..off + del, ins);
        }
        String::from_utf16(&units).unwrap()
    }

    #[test]
    fn hunks_reproduce_the_incoming_text() {
        for (c, i) in [
            ("", ""),
            ("", "abc"),
            ("abc", ""),
            ("same", "same"),
            ("a\nb\nc\n", "a\nB\nc\n"),
            ("x📝y\nz\n", "x🚀y\nz\nw"),
            ("l1\r\nl2\r\nl3\r\n", "l1\r\nL2\r\nl3\r\nl4"),
            ("é\nê\n", "ê\né\n"),
        ] {
            assert_eq!(apply(c, i), i, "{c:?} -> {i:?}");
        }
    }

    #[test]
    fn hunks_leave_unchanged_lines_alone() {
        let cur: String = (0..300).map(|n| format!("line {n}\n")).collect();
        let inc = cur
            .replace("line 2\n", "line two\n")
            .replace("line 200\n", "line two hundred\n");
        let h = hunks(&cur, &inc);
        assert_eq!(h.len(), 2);
        // Neither touches line 100.
        let l100 = cur.find("line 100\n").unwrap();
        for (off, del, _, _) in h {
            assert!(off + del <= l100 || off >= l100 + 9);
        }
        assert_eq!(apply(&cur, &inc), inc);
    }

    #[test]
    fn hunks_identical_is_empty() {
        assert!(hunks("a\nb\n", "a\nb\n").is_empty());
    }

    #[test]
    fn hunks_full_rewrite_of_a_big_note_is_bounded() {
        // Every line differs: the worst case for Myers. The deadline bounds
        // it and the result is still exact.
        let cur: String = (0..20_000).map(|n| format!("old line {n} with text\n")).collect();
        let inc: String = (0..20_000).map(|n| format!("new row {n} other words\n")).collect();
        let t = std::time::Instant::now();
        assert_eq!(apply(&cur, &inc), inc);
        assert!(t.elapsed().as_secs() < 2);
    }
}
