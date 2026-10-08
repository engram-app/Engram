//! What `Engram.MCP.Sections` needs from a CommonMark parse of a note, and
//! nothing else, in one call from the note as stored: its document-level
//! headings, finished (trimmed text and raw source), the lines the parse explains
//! (heading lines at any depth, thematic breaks), and the line ranges where a
//! heading-shaped line may sit hidden (closed fences, closed HTML comments,
//! masked `$$` math). The rules are the ones `Sections.scan/1` applied to
//! mdex_native's AST before this port, kept rule for rule; the comrak
//! version and options are the ones mdex_native 0.2.9 used.
//!
//! Lines are 0-indexed and counted by `\n` only. Traversal is iterative
//! (`descendants`), so deep nesting cannot overflow a scheduler stack.
use std::borrow::Cow;
use std::cell::Cell;
use std::collections::HashSet;
use std::sync::Arc;

use comrak::nodes::{AstNode, NodeValue};
use comrak::{parse_document, Arena, Options, ResolvedReference};

use crate::links::{segmented, SEGMENT};

/// `(line, level, text, raw, span)`: `text` is the rendered inline text
/// (`**A**` -> "A"), `raw` the inline source as written; see `finish`.
pub type Heading = (usize, u8, String, String, usize);

/// `(headings, explained lines, safe line ranges)`, sorted.
pub type Outline = (Vec<Heading>, Vec<usize>, Vec<(usize, usize)>);

/// A heading as parsed: `(line, level, setext, plain_text, raw, span)`,
/// `plain_text` untrimmed, `raw` the source from the heading's start to its
/// last inline node's end (None when it has no inline content).
type Parsed = (usize, u8, bool, String, Option<String>, usize);
type ParsedOutline = (Vec<Parsed>, Vec<usize>, Vec<(usize, usize)>);

// `to` of a range that runs to end of input (Elixir's `:infinity`).
const OPEN: usize = usize::MAX;

/// Most headings + explained lines + safe ranges one outline may return. The
/// parse is bounded per segment, but the result grows with the note: 10 MB
/// of `#` lines is 5M headings, ~400 MB here and more again as BEAM terms.
/// Real notes have hundreds; past this the note is refused (`TooComplex`)
/// and parsing stops. At the cap the result is ~10 MB.
pub const MAX_ITEMS: usize = 100_000;

/// Code spans/blocks the `%%`/`$$` pass may collect (24 bytes each).
const MAX_CODE: usize = 1_000_000;

#[derive(Debug, PartialEq)]
pub enum Refused {
    /// More than `MAX_ITEMS` (or `MAX_CODE`).
    TooComplex,
    /// A sourcepos outside the text (never seen).
    BadSourcepos,
}

// GFM tables (so a delimiter row is never a setext underline) and
// strikethrough (heading text), matching what Obsidian renders. Raw HTML
// stays at the CommonMark default. Frontmatter is NOT comrak's
// front_matter_delimiter: Sections blanks it first with Frontmatter.split/1,
// Engram's one definition of it (CRLF fences included).
fn options<'c>() -> Options<'c> {
    let mut o = Options::default();
    o.extension.table = true;
    o.extension.strikethrough = true;
    o
}

pub fn outline(input: &str) -> Result<Outline, Refused> {
    let note = input.strip_prefix('\u{feff}').unwrap_or(input);
    let (hs, explained, safe) = outline_segmented(&blank_frontmatter(note), SEGMENT)?;
    Ok((hs.into_iter().map(finish).collect(), explained, safe))
}

// The frontmatter block (`Frontmatter.split/1`'s rule, the one Engram uses
// everywhere) as as many empty lines, so line numbers do not move.
fn blank_frontmatter(s: &str) -> Cow<'_, str> {
    match crate::frontmatter::split(s.as_bytes()) {
        None => Cow::Borrowed(s),
        Some((_, _, body, _)) => {
            let blank = "\n".repeat(s[..body].matches('\n').count());
            Cow::Owned(blank + &s[body..])
        }
    }
}

// Trimmed as `String.trim/1` trims (both are Unicode White_Space). `raw`
// drops an ATX heading's `#`s; a multi-line setext heading's lines are
// trimmed and joined with a space, as its rendered text is.
fn finish((line, level, setext, text, raw, span): Parsed) -> Heading {
    let raw = raw.map_or_else(String::new, |r| {
        let r = r.trim_start();
        let r = if setext {
            r
        } else {
            r.get(usize::from(level)..).unwrap_or("")
        };
        r.split('\n')
            .map(str::trim)
            .collect::<Vec<_>>()
            .join(" ")
            .trim()
            .to_string()
    });
    (line, level, text.trim().to_string(), raw, span)
}

/// The outline, parsed in segments of about `segment` bytes cut where
/// `links::segmented` cuts. comrak's arena is ~130-250x what it parses, so
/// only one segment's tree is alive at a time. Segmenting does not change
/// the result (fuzzed below) with two document-wide inputs computed first:
/// the `%%`/`$$` masking, and which reference labels the note defines (a
/// `[x]` in a heading renders as a link when `[x]: /u` is anywhere).
fn outline_segmented(input: &str, segment: usize) -> Result<ParsedOutline, Refused> {
    let text = lone_cr_as_space(input);
    if text.len() > u32::MAX as usize {
        return Err(Refused::TooComplex);
    }
    let starts = Lines::new(&text);
    let opts = options();

    let stop = Cell::new(false);
    let (masked, math) = if text.contains("%%") || text.contains("$$") {
        let mut code = Vec::new();
        each_segment(
            &text,
            &starts,
            &opts,
            segment,
            &stop,
            |doc, seg, out| code_ranges(doc, seg, &starts, out),
            |mut r| {
                code.append(&mut r);
                stop.set(code.len() > MAX_CODE);
            },
        );
        if stop.get() {
            return Err(Refused::TooComplex);
        }
        match mask_obsidian(&text, &starts, &code) {
            Some((m, math)) => (Cow::Owned(m), math),
            None => (Cow::Borrowed(&*text), Vec::new()),
        }
    } else {
        (Cow::Borrowed(&*text), Vec::new())
    };

    // Resolved as the whole document would: a label defined anywhere links.
    // ponytail: this also lifts comrak's 100 KB cap on expanded reference
    // URLs, which guards HTML output; an outline renders no URLs.
    let labels = defined_labels(&masked, segment);
    let mut opts = options();
    opts.parse.broken_link_callback = Some(Arc::new(|r: comrak::options::BrokenLinkReference| {
        labels.contains(r.normalized).then(|| ResolvedReference {
            url: String::new(),
            title: String::new(),
        })
    }));

    let (mut headings, mut explained, mut safe) = (Vec::new(), Vec::new(), math);
    let mut bad = false;
    each_segment(
        &masked,
        &starts,
        &opts,
        segment,
        &stop,
        |doc, seg, out| {
            out.push(collect(doc, seg, &text));
        },
        |parts| {
            for part in parts {
                match part {
                    Some((h, e, s)) => {
                        headings.extend(h);
                        explained.extend(e);
                        safe.extend(s);
                    }
                    None => bad = true,
                }
            }
            stop.set(bad || headings.len() + explained.len() + safe.len() > MAX_ITEMS);
        },
    );
    if bad {
        return Err(Refused::BadSourcepos);
    }
    if stop.get() {
        return Err(Refused::TooComplex);
    }
    explained.sort_unstable();
    explained.dedup();
    safe.sort_unstable();
    Ok((headings, explained, safe))
}

/// Line start offsets as u32 (input is refused past 4 GB), sized up front:
/// 4 bytes a line, so a note of blank lines costs 4x its size, never the
/// 16x+ of a doubling Vec<usize>.
struct Lines(Vec<u32>);

impl Lines {
    fn new(s: &str) -> Self {
        let mut v = Vec::with_capacity(s.matches('\n').count() + 1);
        v.push(0);
        v.extend(s.match_indices('\n').map(|(i, _)| (i + 1) as u32));
        Lines(v)
    }

    fn len(&self) -> usize {
        self.0.len()
    }

    fn get(&self, i: usize) -> Option<usize> {
        self.0.get(i).map(|&x| x as usize)
    }

    fn at(&self, i: usize) -> usize {
        self.0[i] as usize
    }

    /// 0-indexed line containing byte `off`.
    fn line_of(&self, off: usize) -> usize {
        self.0.partition_point(|&x| x as usize <= off) - 1
    }
}

/// Where a segment sits in the whole text. comrak's sourcepos is 1-based
/// lines and 1-based BYTE columns within the segment.
struct Seg {
    at: usize,
    first_line: usize,
    starts: Lines,
}

impl Seg {
    /// 0-indexed line in the whole text.
    fn line(&self, l: usize) -> usize {
        self.first_line + l - 1
    }

    /// Byte offset in the whole text of 0-based byte `col` on 1-based line `l`.
    fn off(&self, l: usize, col: usize) -> Option<usize> {
        Some(self.at + self.starts.get(l - 1)? + col)
    }

    fn lines<'a>(&self, n: &'a AstNode<'a>) -> (usize, usize) {
        let sp = n.data.borrow().sourcepos;
        (self.line(sp.start.line), self.line(sp.end.line))
    }
}

/// Parses `text` in segments (see `links::segmented`) and runs `visit` on
/// each segment's tree; a segment whose last block may still be open is
/// re-parsed longer, and only accepted segments' items reach `accept`.
/// Once `stop` is set, the rest is skipped unparsed.
fn each_segment<T>(
    text: &str,
    starts: &Lines,
    opts: &Options,
    segment: usize,
    stop: &Cell<bool>,
    mut visit: impl for<'a> FnMut(&'a AstNode<'a>, &Seg, &mut Vec<T>),
    accept: impl FnMut(Vec<T>),
) {
    segmented(
        text,
        segment,
        |s, at, out| {
            // Refused: skip the remaining segments without parsing them.
            if stop.get() {
                return None;
            }
            let seg = Seg {
                at,
                first_line: starts.line_of(at),
                starts: Lines::new(s),
            };
            let arena = Arena::new();
            let doc = parse_document(&arena, s, opts);
            visit(doc, &seg, out);
            open_block(doc, &seg.starts, s)
        },
        accept,
    );
}

/// Byte offset in `s` of the first fenced code or raw-HTML block that may
/// continue past the end of `s` (`segmented`'s contract).
fn open_block<'a>(doc: &'a AstNode<'a>, starts: &Lines, s: &str) -> Option<usize> {
    // 1-based number of the last line with content.
    let last = starts.len() - usize::from(s.ends_with('\n'));
    doc.descendants().find_map(|n| {
        let d = n.data.borrow();
        let open = match &d.value {
            NodeValue::CodeBlock(cb) => cb.fenced && !cb.closed,
            // Types 1-5 end at their marker (blank lines included), 6-7 at
            // a blank line.
            NodeValue::HtmlBlock(h) => match h.block_type {
                1 => {
                    let l = h.literal.to_ascii_lowercase();
                    !["</script>", "</pre>", "</style>", "</textarea>"]
                        .iter()
                        .any(|m| l.contains(m))
                }
                2 => !h.literal.contains("-->"),
                3 => !h.literal.contains("?>"),
                4 => !h.literal.contains('>'),
                5 => !h.literal.contains("]]>"),
                _ => d.sourcepos.end.line >= last,
            },
            _ => false,
        };
        open.then(|| starts.at(d.sourcepos.start.line - 1))
    })
}

/// Every reference label `text` defines, normalized as comrak looks it up.
/// Candidates are the `[label]` before each `]:`; comrak decides which are
/// definitions (a probe `[label]` paragraph before the segment links), and
/// a second parse with no definitions reports each one's normalized form.
fn defined_labels(text: &str, segment: usize) -> HashSet<String> {
    if !text.contains("]:") {
        return HashSet::new();
    }
    let opts = options();
    let mut defined: Vec<String> = Vec::new();
    segmented(
        text,
        segment,
        |s, _, out| {
            let cands = candidates(s);
            let probe = probes(&cands);
            let full = format!("{probe}{s}");
            let arena = Arena::new();
            let doc = parse_document(&arena, &full, &opts);
            out.extend(linked_probes(doc, cands.len()).map(|i| cands[i].clone()));
            let fs = Lines::new(&full);
            open_block(doc, &fs, &full).map(|o| o.saturating_sub(probe.len()))
        },
        |mut d| defined.append(&mut d),
    );
    defined.sort_unstable();
    defined.dedup();

    let mut opts = options();
    opts.parse.broken_link_callback = Some(Arc::new(|r: comrak::options::BrokenLinkReference| {
        Some(ResolvedReference {
            url: r.normalized.to_string(),
            title: String::new(),
        })
    }));
    // In batches, one tree alive at a time: one parse of every label was a
    // whole note's worth of tree (9.7 MB of `[nN]: /u` peaked at 1.06 GB).
    let mut out = HashSet::with_capacity(defined.len());
    for batch in defined.chunks(LABEL_BATCH) {
        let arena = Arena::new();
        let doc = parse_document(&arena, &probes(batch), &opts);
        out.extend(
            doc.children()
                .filter_map(|p| match &p.first_child()?.data.borrow().value {
                    NodeValue::Link(l) => Some(l.url.clone()),
                    _ => None,
                }),
        );
    }
    out
}

/// Labels normalized per comrak parse in `defined_labels`: ~1,000 short
/// probes is a tree of a few MB.
const LABEL_BATCH: usize = 1_000;

// "[c]\n\n" per candidate: probe i is the paragraph on line 2i + 1. Line
// breaks inside a label become spaces (normalization collapses them).
fn probes(cands: &[String]) -> String {
    cands
        .iter()
        .map(|c| format!("[{}]\n\n", c.replace(['\r', '\n'], " ")))
        .collect()
}

// Indices of the probes that parsed as a link.
fn linked_probes<'a>(doc: &'a AstNode<'a>, n: usize) -> impl Iterator<Item = usize> + 'a {
    doc.children().filter_map(move |p| {
        let line = p.data.borrow().sourcepos.start.line;
        let i = (line - 1) / 2;
        let link = matches!(
            p.first_child()
                .map(|c| matches!(c.data.borrow().value, NodeValue::Link(_))),
            Some(true)
        );
        (line % 2 == 1 && i < n && link).then_some(i)
    })
}

// The text of each unescaped `[...]` that ends right before a `]:`, up to
// comrak's 999-byte label limit, deduplicated.
fn candidates(s: &str) -> Vec<String> {
    let b = s.as_bytes();
    let escaped = |i: usize| b[..i].iter().rev().take_while(|&&c| c == b'\\').count() % 2 == 1;
    let mut out: Vec<String> = s
        .match_indices("]:")
        .filter(|&(j, _)| !escaped(j))
        .filter_map(|(j, _)| {
            let lo = j.saturating_sub(1000);
            let k = (lo..j)
                .rev()
                .find(|&k| matches!(b[k], b'[' | b']') && !escaped(k))?;
            (b[k] == b'[' && j - k > 1).then(|| s[k + 1..j].to_string())
        })
        .collect();
    out.sort_unstable();
    out.dedup();
    out
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

// One segment's outline. Lines and offsets are in the whole text.
fn collect<'a>(doc: &'a AstNode<'a>, seg: &Seg, text: &str) -> Option<ParsedOutline> {
    let (mut explained, mut safe) = (Vec::new(), Vec::new());
    for n in doc.descendants() {
        let (l1, l2) = seg.lines(n);
        match &n.data.borrow().value {
            NodeValue::Heading(_) => {
                explained.extend(if l1 == l2 { vec![l1] } else { vec![l1, l2] })
            }
            NodeValue::ThematicBreak => explained.push(l1),
            NodeValue::CodeBlock(cb) if cb.fenced && cb.closed => safe.push((l1, l2)),
            NodeValue::HtmlBlock(h) if h.block_type == 2 && h.literal.contains("-->") => {
                safe.push((l1, l2))
            }
            _ => {}
        }
    }

    let mut headings = Vec::new();
    for h in doc.children() {
        let (level, setext) = match &h.data.borrow().value {
            NodeValue::Heading(nh) => (nh.level, nh.setext),
            _ => continue,
        };
        let (l1, l2) = seg.lines(h);
        let raw = match h.last_child() {
            None => None,
            Some(last) => {
                let sp = h.data.borrow().sourcepos;
                let end = last.data.borrow().sourcepos.end;
                let from = seg.off(sp.start.line, sp.start.column - 1)?;
                let to = seg.off(end.line, end.column)?;
                Some(text.get(from..to)?.to_string())
            }
        };
        headings.push((l1, level, setext, plain_text(h), raw, l2 - l1 + 1));
    }

    Some((headings, explained, safe))
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

// Byte ranges (`to` exclusive, OPEN = to end) of code blocks, code spans
// and HTML blocks (flagged true; used for `$$` pairing only), in document
// order, offsets in the whole text.
fn code_ranges<'a>(
    doc: &'a AstNode<'a>,
    seg: &Seg,
    starts: &Lines,
    out: &mut Vec<(usize, usize, bool)>,
) {
    let block = |n: &'a AstNode<'a>, html| {
        let (l1, l2) = seg.lines(n);
        (starts.at(l1), starts.get(l2 + 1).unwrap_or(OPEN), html)
    };
    for n in doc.descendants() {
        match &n.data.borrow().value {
            NodeValue::HtmlBlock(_) => out.push(block(n, true)),
            NodeValue::CodeBlock(_) => out.push(block(n, false)),
            NodeValue::Code(_) => {
                let sp = n.data.borrow().sourcepos;
                if let (Some(a), Some(b)) = (
                    seg.off(sp.start.line, sp.start.column - 1),
                    seg.off(sp.end.line, sp.end.column),
                ) {
                    out.push((a, b, false));
                }
            }
            _ => {}
        }
    }
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
fn mask_obsidian(
    text: &str,
    starts: &Lines,
    code: &[(usize, usize, bool)],
) -> Option<(String, Vec<(usize, usize)>)> {
    let pct: Vec<usize> = text.match_indices("%%").map(|(i, _)| i).collect();
    let dollars: Vec<usize> = text.match_indices("$$").map(|(i, _)| i).collect();
    if pct.is_empty() && dollars.is_empty() {
        return None;
    }

    let mut masked = text.as_bytes().to_vec();
    let ranges = |html: bool| -> Vec<(usize, usize)> {
        code.iter()
            .filter(|r| html || !r.2)
            .map(|&(a, b, _)| (a, b))
            .collect()
    };
    for pair in outside(&pct, &ranges(false)).chunks(2) {
        let end = pair.get(1).map_or(masked.len(), |c| c + 2);
        blank(&mut masked[pair[0]..end]);
    }

    let mut toks: Vec<usize> = outside(&dollars, &ranges(true))
        .into_iter()
        .filter(|&d| &masked[d..d + 2] == b"$$")
        .collect();
    if toks.len() % 2 == 1 {
        toks.clear();
    }
    let line_of = |off: usize| starts.line_of(off);
    let math: Vec<(usize, usize)> = toks
        .chunks(2)
        .map(|p| (line_of(p[0]), line_of(p[1])))
        .filter(|(a, b)| a != b)
        .collect();
    for &(l1, l2) in &math {
        let to = starts.get(l2 + 1).map_or(masked.len(), |s| s - 1);
        blank(&mut masked[starts.at(l1)..to]);
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
        let shape: Vec<_> = hs.iter().map(|h| (h.0, h.1, h.4)).collect();
        assert_eq!(shape, vec![(0, 1, 1), (6, 1, 2)]);
        assert_eq!((hs[0].2.as_str(), hs[0].3.as_str()), ("A", "A"));
        assert_eq!(explained, vec![0, 6, 7, 9]);
        assert_eq!(safe, vec![(2, 4)]);
    }

    #[test]
    fn bom_frontmatter_and_trimming() {
        let note = "\u{feff}---\na: 1\n---\n#  **B**\u{a0} #\n  x \r\n y\n===\n";
        let (hs, explained, _) = outline(note).unwrap();
        let got: Vec<_> = hs
            .iter()
            .map(|h| (h.0, h.2.as_str(), h.3.as_str()))
            .collect();
        assert_eq!(got, vec![(3, "B", "**B**"), (4, "x y", "x y")]);
        assert_eq!(explained, vec![3, 4, 6]);
    }

    #[test]
    fn too_many_items_is_refused_early() {
        use super::{Refused, MAX_ITEMS};
        let ok = "#\n".repeat(MAX_ITEMS / 2 - 1);
        assert!(outline(&ok).is_ok());
        let over = "#\n".repeat(MAX_ITEMS);
        assert_eq!(outline(&over), Err(Refused::TooComplex));
        assert_eq!(
            outline(&format!("\n{}", "---\n\n".repeat(MAX_ITEMS + 1))),
            Err(Refused::TooComplex)
        );
        assert_eq!(
            outline(&"%% `a`\n".repeat(1_100_000)),
            Err(Refused::TooComplex)
        );
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
        assert!(outline(&deep).is_ok());
    }

    // Review of #1895: a fence holding a line too long to find a safe cut in
    // was cut by force and accepted while still open, so `# not heading`
    // became a heading and the closing fence opened a new one that ate `# B`.
    #[test]
    fn a_forced_cut_never_splits_an_open_fence() {
        let doc = format!(
            "# A\n\n```\n{}\n# not heading\n```\n\n# B\n",
            "x".repeat(200_000)
        );
        let seg = super::outline_segmented(&doc, super::SEGMENT).unwrap();
        assert_eq!(seg, super::outline_segmented(&doc, usize::MAX).unwrap());
        let names: Vec<_> = seg.0.iter().map(|h| h.3.as_str()).collect();
        assert_eq!(names, ["A", "B"]);
        assert_eq!(seg.2, vec![(2, 5)]);
    }

    // Review of #1895: the label normalization parsed every defined label in
    // one comrak call: 9.7 MB of distinct `[nN]: /u` peaked at 1.06 GB.
    #[test]
    fn defined_labels_parse_in_bounded_batches() {
        let defs: String = (0..150_000).map(|i| format!("[n{i}]: /u\n\n")).collect();
        let (labels, peak) =
            crate::memory::measured(|| super::defined_labels(&defs, super::SEGMENT));
        assert_eq!(labels.len(), 150_000);
        assert!(peak < 120_000_000, "{peak} for {} B", defs.len());
    }

    #[test]
    fn a_reference_defined_in_another_segment_links() {
        let doc = "# [Foo  Bar] *[x*]\n\npara\n\n[foo\nbar]: /u\n\n[x*]: /v\n";
        let whole = super::outline_segmented(doc, usize::MAX).unwrap();
        assert_eq!(whole.0[0].3, "Foo  Bar *x*");
        assert_eq!(super::outline_segmented(doc, 1).unwrap(), whole);
        // Masked away, it defines nothing.
        let hidden = "# [a]\n\n%%\n[a]: /u\n%%\n";
        assert_eq!(super::outline_segmented(hidden, 1).unwrap().0[0].3, "[a]");
    }

    // Segmenting must never change the outline. Cut as often as possible
    // (segment = 1) on markup built from what spans lines or segments:
    // fences, HTML, quotes, lists, setext, tables, `%%`, `$$`, references.
    // ENGRAM_FUZZ_CASES=2000000 ENGRAM_FUZZ_SEED=7 cargo test --release outline_segmented
    #[test]
    fn outline_segmented_equals_whole_document() {
        let pieces = [
            "```",
            "~~~",
            "\n",
            "\n\n",
            "    ",
            "- ",
            "1. ",
            "> ",
            "`",
            "<!--",
            "-->",
            "<pre>",
            "</pre>",
            "<?",
            "?>",
            "<!X",
            ">",
            "<![CDATA[",
            "]]>",
            "<div>",
            "text",
            "\t",
            "***",
            "---",
            "| a |",
            "|---|",
            "a | b",
            "*",
            "\r",
            " ",
            "# ",
            "## ",
            "#",
            "===",
            "Title\n===\n",
            "%%",
            "$$",
            "[x]",
            "[x]: /u",
            "[X ]:",
            "[y]",
            "\\",
            "]:",
            "[",
            "]",
            "~~",
            "1. x\n2. y",
        ];
        let env = |k: &str| std::env::var(k).ok().and_then(|v| v.parse::<u64>().ok());
        let cases = env("ENGRAM_FUZZ_CASES").unwrap_or(20_000);
        let mut seed: u64 = env("ENGRAM_FUZZ_SEED").map_or(0x9E37_79B9_7F4A_7C15, |s| {
            s.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1
        });
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        for _ in 0..cases {
            let n = 1 + (next() % 40) as usize;
            let doc: String = (0..n)
                .map(|_| pieces[(next() % pieces.len() as u64) as usize])
                .collect();
            assert_eq!(
                super::outline_segmented(&doc, 1),
                super::outline_segmented(&doc, usize::MAX),
                "{doc:?}"
            );
        }
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
