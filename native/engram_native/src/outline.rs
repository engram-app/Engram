//! What `Engram.MCP.Sections` needs from a CommonMark parse of a note, and
//! nothing else: its document-level headings, the lines the parse explains
//! (heading lines at any depth, thematic breaks), and the line ranges where a
//! heading-shaped line may sit hidden (closed fences, closed HTML comments,
//! masked `$$` math). The rules are the ones `Sections.scan/1` applied to
//! mdex_native's AST before this port, kept rule for rule; the comrak
//! version and options are the ones mdex_native 0.2.9 used.
//!
//! Lines are 0-indexed and counted by `\n` only. Traversal is iterative
//! (`descendants`), so deep nesting cannot overflow a scheduler stack.
use std::borrow::Cow;

use comrak::nodes::{AstNode, NodeValue};
use comrak::{parse_document, Arena, Options};

/// `(line, level, setext, plain_text, raw, span)`. `plain_text` is the
/// rendered inline text, untrimmed; `raw` is the source from the heading's
/// start to its last inline node's end (None when it has no inline content).
/// Elixir trims both: its notion of whitespace is the definition.
pub type Heading = (usize, u8, bool, String, Option<String>, usize);

/// `(headings, explained lines, safe line ranges)`, sorted.
pub type Outline = (Vec<Heading>, Vec<usize>, Vec<(usize, usize)>);

// `to` of a range that runs to end of input (Elixir's `:infinity`).
const OPEN: usize = usize::MAX;

// GFM tables (so a delimiter row is never a setext underline) and
// strikethrough (heading text), matching what Obsidian renders. Raw HTML
// stays at the CommonMark default. Frontmatter is NOT comrak's
// front_matter_delimiter: Sections blanks it first with Frontmatter.split/1,
// Engram's one definition of it (CRLF fences included).
fn options() -> Options<'static> {
    let mut o = Options::default();
    o.extension.table = true;
    o.extension.strikethrough = true;
    o
}

/// `None` only if a sourcepos points outside the text (never seen; the
/// Elixir version raised there too).
pub fn outline(input: &str) -> Option<Outline> {
    let text = lone_cr_as_space(input);
    let starts: Vec<usize> = std::iter::once(0)
        .chain(text.match_indices('\n').map(|(i, _)| i + 1))
        .collect();
    let opts = options();

    // The first tree is dropped before the re-parse: comrak's arena is
    // ~130-250x the note, and two at once doubled the peak.
    let (masked, math) = {
        let arena = Arena::new();
        let first = parse_document(&arena, &text, &opts);
        match mask_obsidian(&text, &starts, first) {
            None => return collect(first, &text, &starts, Vec::new()),
            Some(m) => m,
        }
    };
    let arena = Arena::new();
    collect(parse_document(&arena, &masked, &opts), &text, &starts, math)
}

// CommonMark also ends a line at a lone "\r"; callers count lines by "\n"
// only, so a lone "\r" becomes a space (same byte offsets). Borrows when
// there is none (the common case); otherwise copies once, str slice by str
// slice, so nothing is re-validated as UTF-8.
fn lone_cr_as_space(input: &str) -> Cow<'_, str> {
    let b = input.as_bytes();
    // match_indices on a char searches with memchr.
    if !input
        .match_indices('\r')
        .any(|(i, _)| b.get(i + 1) != Some(&b'\n'))
    {
        return Cow::Borrowed(input);
    }
    let mut out = String::with_capacity(input.len());
    let mut pieces = input.split('\r');
    out.push_str(pieces.next().unwrap_or_default());
    for piece in pieces {
        out.push(if piece.starts_with('\n') { '\r' } else { ' ' });
        out.push_str(piece);
    }
    Cow::Owned(out)
}

// The outline of the final tree. `safe` starts as the masked math ranges.
fn collect<'a>(
    doc: &'a AstNode<'a>,
    text: &str,
    starts: &[usize],
    mut safe: Vec<(usize, usize)>,
) -> Option<Outline> {
    let mut explained = Vec::new();
    for n in doc.descendants() {
        let (l1, l2) = lines(n);
        match &n.data.borrow().value {
            NodeValue::Heading(_) => explained.extend([l1, l2]),
            NodeValue::ThematicBreak => explained.push(l1),
            NodeValue::CodeBlock(cb) if cb.fenced && cb.closed => safe.push((l1, l2)),
            NodeValue::HtmlBlock(h) if h.block_type == 2 && h.literal.contains("-->") => {
                safe.push((l1, l2))
            }
            _ => {}
        }
    }
    explained.sort_unstable();
    explained.dedup();
    safe.sort_unstable();

    let mut headings = Vec::new();
    for h in doc.children() {
        let (level, setext) = match &h.data.borrow().value {
            NodeValue::Heading(nh) => (nh.level, nh.setext),
            _ => continue,
        };
        let (l1, l2) = lines(h);
        let raw = match h.last_child() {
            None => None,
            Some(last) => {
                let sp = h.data.borrow().sourcepos;
                let end = last.data.borrow().sourcepos.end;
                let from = starts.get(sp.start.line - 1)? + sp.start.column - 1;
                let to = starts.get(end.line - 1)? + end.column;
                Some(text.get(from..to)?.to_string())
            }
        };
        headings.push((l1, level, setext, plain_text(h), raw, l2 - l1 + 1));
    }

    Some((headings, explained, safe))
}

fn lines<'a>(n: &'a AstNode<'a>) -> (usize, usize) {
    let sp = n.data.borrow().sourcepos;
    (sp.start.line - 1, sp.end.line - 1)
}

// Inline markup rendered to its text: `**B**` -> "B", `[l](u)` -> "l", a
// code span -> its content, a soft/hard break -> " ". Raw inline HTML keeps
// its literal.
fn plain_text<'a>(h: &'a AstNode<'a>) -> String {
    let mut out = String::new();
    for n in h.descendants().skip(1) {
        match &n.data.borrow().value {
            NodeValue::Text(t) => out.push_str(t),
            NodeValue::Code(c) => out.push_str(&c.literal),
            NodeValue::HtmlInline(s) => out.push_str(s),
            NodeValue::SoftBreak | NodeValue::LineBreak => out.push(' '),
            _ => {}
        }
    }
    out
}

// Byte ranges (`to` exclusive, OPEN = to end) of code blocks and code spans,
// in document order; with `html`, HTML blocks too (for `$$` pairing only).
// sourcepos columns are 1-based BYTE columns.
fn code_ranges<'a>(doc: &'a AstNode<'a>, starts: &[usize], html: bool) -> Vec<(usize, usize)> {
    let block = |n: &'a AstNode<'a>| {
        let (l1, l2) = lines(n);
        (starts[l1], starts.get(l2 + 1).copied().unwrap_or(OPEN))
    };
    let mut out = Vec::new();
    for n in doc.descendants() {
        match &n.data.borrow().value {
            NodeValue::HtmlBlock(_) if html => out.push(block(n)),
            NodeValue::CodeBlock(_) => out.push(block(n)),
            NodeValue::Code(_) => {
                let sp = n.data.borrow().sourcepos;
                out.push((
                    starts[sp.start.line - 1] + sp.start.column - 1,
                    starts[sp.end.line - 1] + sp.end.column,
                ))
            }
            _ => {}
        }
    }
    out
}

// Marks not inside any range. Both sorted: a merge walk.
fn outside(marks: &[usize], ranges: &[(usize, usize)]) -> Vec<usize> {
    let (mut out, mut r, mut i) = (Vec::new(), 0, 0);
    while i < marks.len() {
        let m = marks[i];
        if r < ranges.len() && m >= ranges[r].1 {
            r += 1;
        } else {
            if r >= ranges.len() || m < ranges[r].0 {
                out.push(m);
            }
            i += 1;
        }
    }
    out
}

fn blank(b: &mut [u8]) {
    for x in b.iter_mut().filter(|x| **x != b'\n') {
        *x = b' ';
    }
}

// Obsidian syntax CommonMark does not know, masked to spaces (newlines
// kept, so lines and byte offsets do not move) before ONE re-parse. Code
// (code blocks and inline code spans) comes from the first parse; neither
// construct is recognized inside it. Returns the masked text and the
// 0-indexed line ranges of the masked math blocks (closed, so allow-listed
// like a closed fence), or None when nothing was masked.
//
//   * `%%` comments: every `%%` outside code toggles a comment; an
//     unclosed `%%` hides everything after it.
//   * `$$` display math: `$$` tokens outside code, HTML blocks and `%%`
//     comments pair in order; a pair spanning lines masks those lines. Its
//     lines are TeX, not markdown (a `## x` inside is no heading). An odd
//     token count masks nothing: a guessed pairing that swallows a real
//     heading would also allow-list it, and a write would delete it.
//     comrak's math_dollars extension does not help: it parses `$$` as
//     INLINE math, after block structure has already made `## x` a heading.
//
// ponytail: one pass. Code spans come from the UNmasked parse, so a
// backtick inside a `%%` comment can pair with one after it and mis-pair
// later `%%`s. Sections.find/4's hidden-heading check turns that into a
// refused write rather than a wrong section; a fixed-point loop would fix
// the read.
fn mask_obsidian<'a>(
    text: &str,
    starts: &[usize],
    doc: &'a AstNode<'a>,
) -> Option<(String, Vec<(usize, usize)>)> {
    let pct: Vec<usize> = text.match_indices("%%").map(|(i, _)| i).collect();
    let dollars: Vec<usize> = text.match_indices("$$").map(|(i, _)| i).collect();
    if pct.is_empty() && dollars.is_empty() {
        return None;
    }

    let mut masked = text.as_bytes().to_vec();
    for pair in outside(&pct, &code_ranges(doc, starts, false)).chunks(2) {
        let end = pair.get(1).map_or(masked.len(), |c| c + 2);
        blank(&mut masked[pair[0]..end]);
    }

    let mut toks: Vec<usize> = outside(&dollars, &code_ranges(doc, starts, true))
        .into_iter()
        .filter(|&d| &masked[d..d + 2] == b"$$")
        .collect();
    if toks.len() % 2 == 1 {
        toks.clear();
    }
    let line_of = |off: usize| starts.partition_point(|&s| s <= off) - 1;
    let math: Vec<(usize, usize)> = toks
        .chunks(2)
        .map(|p| (line_of(p[0]), line_of(p[1])))
        .filter(|(a, b)| a != b)
        .collect();
    for &(l1, l2) in &math {
        let to = starts.get(l2 + 1).map_or(masked.len(), |s| s - 1);
        blank(&mut masked[starts[l1]..to]);
    }

    if masked == text.as_bytes() {
        return None;
    }
    // Only ASCII bytes were overwritten with ASCII, at whole-codepoint
    // ranges (they start and end at `%%`, `$$` or a line boundary).
    Some((String::from_utf8(masked).ok()?, math))
}

#[cfg(test)]
mod tests {
    #[test]
    fn lone_cr_borrows_unless_a_lone_cr_exists() {
        use std::borrow::Cow;
        for s in ["", "a\r\nb\r\n", "no cr", "\u{e9}\r\n\u{1f600}"] {
            assert!(
                matches!(super::lone_cr_as_space(s), Cow::Borrowed(b) if b == s),
                "{s:?}"
            );
        }
        for (s, want) in [
            ("\r", " "),
            ("a\rb", "a b"),
            ("\r\r\n", " \r\n"),
            ("x\r\ny\r", "x\r\ny "),
            ("\u{e9}\r\u{1f600}\r\r", "\u{e9} \u{1f600}  "),
        ] {
            let got = super::lone_cr_as_space(s);
            assert!(matches!(got, Cow::Owned(_)), "{s:?}");
            assert_eq!(got, want, "{s:?}");
        }
    }
    use super::outline;

    #[test]
    fn headings_and_ranges() {
        let (hs, explained, safe) = outline("# A\n\n```\n# x\n```\n\nB\n=\n\n---\n").unwrap();
        let shape: Vec<_> = hs.iter().map(|h| (h.0, h.1, h.2)).collect();
        assert_eq!(shape, vec![(0, 1, false), (6, 1, true)]);
        assert_eq!(hs[0].3, "A");
        assert_eq!(hs[0].4.as_deref(), Some("# A"));
        assert_eq!(explained, vec![0, 6, 7, 9]);
        assert_eq!(safe, vec![(2, 4)]);
    }

    #[test]
    fn comments_and_math_are_masked() {
        let (hs, _, safe) = outline("%%\n# hidden\n%%\n$$\n# tex\n$$\n# real\n").unwrap();
        let lines: Vec<_> = hs.iter().map(|h| h.0).collect();
        assert_eq!(lines, vec![6]);
        assert_eq!(safe, vec![(3, 5)]);
    }

    #[test]
    fn empty_and_deep_nesting() {
        assert!(outline("").unwrap().0.is_empty());
        // No recursion over the tree: deep nesting cannot overflow a stack.
        let deep = format!("{}# x\n", "> ".repeat(50_000));
        assert!(outline(&deep).is_some());
    }

    #[test]
    fn linear_time() {
        // Quadratic would take minutes here; linear takes well under a second.
        let block = "## H %% c %% `x`\n\ntext $$ y\n\n```\n# z\n```\n\n$$\n";
        let big = block.repeat(10_000);
        let t = std::time::Instant::now();
        outline(&big).unwrap();
        assert!(t.elapsed().as_secs() < 5);
    }
}
