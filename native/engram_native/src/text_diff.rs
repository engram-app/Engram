//! The single-span diff behind `CrdtBridge.diff_into_text/2`: the longest
//! common codepoint prefix and suffix of the doc's text and the incoming
//! text. Allocates nothing; linear in the inputs.

/// `(prefix_u16, delete_u16, insert_start, insert_len)`. The first two are
/// UTF-16 units into `cur` (the doc is `offset_kind: :utf16`); the insert is
/// a byte range of `inc`, so Elixir slices it with `binary_part` and nothing
/// is copied. The suffix never overlaps the prefix.
pub fn diff(cur: &str, inc: &str) -> (usize, usize, usize, usize) {
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

    (
        utf16_len(&c[..p]),
        utf16_len(&c[p..c.len() - s]),
        p,
        i.len() - s - p,
    )
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
    use super::diff;

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
}
