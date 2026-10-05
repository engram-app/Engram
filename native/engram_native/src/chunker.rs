//! `Engram.Parsers.Markdown.parse/2` in Rust (chunker version 3): the
//! frontmatter split, heading sections, base64 blob stripping, splitting and
//! the size caps. The Elixir side keeps CRLF normalisation, the folder and
//! the title, and assigns positions.
//!
//! Headings come from pulldown-cmark, so a `# comment` inside code is not a
//! heading and setext headings count. Only top-level headings split: one
//! inside a list item or block quote is part of that block.
use crate::links::{segmented, SEGMENT};
use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag, TagEnd};
use regex::Regex;
use std::sync::OnceLock;

macro_rules! re {
    ($pat:expr) => {{
        static RE: OnceLock<Regex> = OnceLock::new();
        RE.get_or_init(|| Regex::new($pat).unwrap())
    }};
}

/// ~4 bytes per token: 512 tokens.
pub const MAX_CHUNK: usize = 2048;
/// The breadcrumb before the text, `folder > title > h1 > h2`.
const MAX_PREFIX: usize = 512;
/// An oversized section is cut where a unit's hash says so (see `anchor`),
/// never before MIN_CHUNK bytes. A cut depends on the unit's own text, not
/// on where the previous chunk began, so an edit re-chunks only its
/// neighbourhood and the rest of the note keeps its embeddings (#1594).
const MIN_CHUNK: usize = 1536;
/// Odds a unit anchors: its length over this (tuned: 20 edits on a 1 MB
/// note re-embed 1.1 chunks each, at +14% chunks over greedy packing).
const ANCHOR_SPAN: u64 = 512;

/// One chunk: (text, context_text, embed_text, heading_path, char_start,
/// char_end). context_text carries the folder for keyword search (#1615);
/// embed_text drops it, so moving a note does not re-embed it (#1621).
pub type Chunk = (String, String, String, String, usize, usize);

struct Heading {
    level: usize,
    start: usize,
    end: usize,
    text: String,
}

/// Chunks of a note: body sections, then one chunk carrying the raw
/// frontmatter block (keyword search reads its keys). `content` is
/// LF-normalised.
#[cfg(test)]
pub fn chunk(content: &str, folder: &str, title: &str) -> Vec<Chunk> {
    let mut out = Vec::new();
    each_chunk(content, folder, title, |c| out.push(c));
    out
}

/// `chunk`, handing each chunk to `emit` as it is made, so a huge note's
/// chunks are never all held in Rust at once.
pub fn each_chunk(content: &str, folder: &str, title: &str, mut emit: impl FnMut(Chunk)) {
    let (block, body) = crate::frontmatter::parts(content);
    let headings = headings(body);
    // The first H1 is the note's title: its place in the path is the title.
    let title_h1 = headings.iter().position(|h| h.level == 1);
    let mut stack: Vec<(usize, &str, bool)> = Vec::new();
    let mut start = 0;
    let mut head: Option<&Heading> = None;
    for (i, next) in headings.iter().map(Some).chain([None]).enumerate() {
        let end = next.map_or(body.len(), |h| h.start);
        let head_end = head.map_or(start, |h| h.end.min(end));
        let rest = strip_blobs(&body[head_end..end]);
        if !markup_only(&rest) {
            let text = normalize(&body[start..head_end], &rest);
            let path = heading_path(title, &stack);
            for t in split(&text) {
                emit(make(folder, &path, &path, t, start, end));
            }
        }
        if let Some(h) = next {
            stack.retain(|&(l, _, _)| l < h.level);
            stack.push((h.level, &h.text, Some(i) == title_h1));
            start = h.start;
        }
        head = next;
    }
    if let Some(block) = block.filter(|b| !b.is_empty()) {
        let text = normalize("", &strip_blobs(&block));
        let path = format!("{title} > frontmatter");
        for t in hard_split(&text, MAX_CHUNK)
            .into_iter()
            .filter(|t| !t.is_empty())
        {
            emit(make(folder, &path, "frontmatter", t, 0, 0));
        }
    }
}

fn make(folder: &str, path: &str, heading_path: &str, text: &str, s: usize, e: usize) -> Chunk {
    let emb = cap(path);
    let ctx = if folder.is_empty() {
        emb.to_string()
    } else {
        cap(&format!("{folder} > {path}")).to_string()
    };
    (
        text.to_string(),
        format!("{ctx}\n\n{text}"),
        format!("{emb}\n\n{text}"),
        heading_path.to_string(),
        s,
        e,
    )
}

/// Voyage rejects an oversized input with a permanent 400, so every prefix
/// is bounded; texts are bounded by `split`.
fn cap(prefix: &str) -> &str {
    hard_split(prefix, MAX_PREFIX)[0]
}

/// Top-level headings, in order. Parsed in segments, as `links` does, so
/// pulldown-cmark's tree stays small on a huge note.
fn headings(body: &str) -> Vec<Heading> {
    if may_have_heading(body) {
        headings_in(body, SEGMENT)
    } else {
        Vec::new()
    }
}

fn headings_in(body: &str, segment: usize) -> Vec<Heading> {
    let mut out = Vec::new();
    segmented(body, segment, &mut out, |s, at, hs| {
        // pulldown-cmark 0.13.4 panics on some valid input (see links).
        // ponytail: a panicking segment loses its headings, not the note;
        // its text still chunks under the previous heading.
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| segment_headings(s, at, hs)))
            .unwrap_or(None)
    });
    out
}

/// ATX needs a `#`, setext an underline line of `=` or `-`. Without either
/// pulldown-cmark finds no heading, and a blob-only note skips the parse.
fn may_have_heading(s: &str) -> bool {
    s.contains('#')
        // pulldown-cmark also ends a line at a lone \r.
        || s.split(['\n', '\r'])
            .any(|l| matches!(l.trim_start().as_bytes().first(), Some(b'=' | b'-')))
}

/// The start of a fenced or raw-HTML block running to the end of `s`, if any.
fn segment_headings(s: &str, at: usize, out: &mut Vec<Heading>) -> Option<usize> {
    let mut depth = 0usize;
    let mut open = None;
    for (event, r) in Parser::new_ext(s, Options::ENABLE_TABLES).into_offset_iter() {
        match event {
            Event::Start(Tag::BlockQuote(_) | Tag::List(_) | Tag::Item) => depth += 1,
            Event::End(TagEnd::BlockQuote(_) | TagEnd::List(_) | TagEnd::Item) => depth -= 1,
            Event::Start(Tag::Heading { level, .. }) if depth == 0 => out.push(Heading {
                level: level as usize,
                start: at + r.start,
                end: at + r.end,
                text: heading_text(&s[r]),
            }),
            Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(_)) | Tag::HtmlBlock)
                if r.end == s.len() =>
            {
                open = open.or(Some(r.start));
            }
            _ => {}
        }
    }
    open
}

/// The heading's source text: ATX without its `#` runs, setext without its
/// underline (lines joined by a space).
fn heading_text(src: &str) -> String {
    let src = src.trim_end();
    let first = src.trim_start();
    let hashes = first.bytes().take_while(|&c| c == b'#').count();
    if (1..=6).contains(&hashes) && !src.contains('\n') {
        let t = first[hashes..].trim();
        // A closing sequence counts only after a space, or as the whole text.
        let closing = t.trim_end_matches('#');
        let t = if closing.is_empty() || closing.ends_with([' ', '\t']) {
            closing.trim_end()
        } else {
            t
        };
        return t.to_string();
    }
    let lines: Vec<&str> = src.lines().collect();
    let body = &lines[..lines.len().saturating_sub(1)];
    body.iter().map(|l| l.trim()).collect::<Vec<_>>().join(" ")
}

fn heading_path(title: &str, stack: &[(usize, &str, bool)]) -> String {
    let mut path = title.to_string();
    for &(_, h, is_title) in stack {
        if !is_title {
            path.push_str(" > ");
            path.push_str(h);
        }
    }
    path
}

/// No letter or digit: blank, a heading alone, or a blob and its markup.
fn markup_only(text: &str) -> bool {
    !re!(r"[\p{L}\p{N}]").is_match(text)
}

/// Trailing spaces cut from each line, blank-line runs cut to one, the
/// whole trimmed: whitespace edits do not change what is embedded.
fn normalize(head: &str, rest: &str) -> String {
    let mut out = String::with_capacity(head.len() + rest.len());
    let mut blank = 0;
    // A heading's source ends at its line break, so the two never share a line.
    for line in head.split('\n').chain(rest.split('\n')) {
        let line = line.trim_end();
        if line.is_empty() {
            blank += 1;
            continue;
        }
        if !out.is_empty() {
            out.push_str(if blank > 0 { "\n\n" } else { "\n" });
        }
        blank = 0;
        out.push_str(line);
    }
    out.truncate(out.trim_end().len());
    let lead = out.len() - out.trim_start().len();
    out.drain(..lead);
    out
}

/// Base64 runs (data URIs, Excalidraw, encrypted blocks) are removed from the
/// indexed text; the note keeps every byte. A run must also LOOK encoded, so
/// a long URL or path in the same character class survives.
fn strip_blobs(text: &str) -> std::borrow::Cow<'_, str> {
    re!(r"(?:data:[A-Za-z0-9_/+.-]+;base64,)?[A-Za-z0-9+/=_-]{100,}").replace_all(
        text,
        |c: &regex::Captures| {
            if encoded(&c[0]) {
                String::new()
            } else {
                c[0].to_string()
            }
        },
    )
}

/// Random base64 is ~41% upper, ~41% lower, ~16% digits. Counted over the
/// first 4 KB.
fn encoded(run: &str) -> bool {
    let sample = &run.as_bytes()[..run.len().min(4096)];
    let (mut u, mut l, mut d) = (0usize, 0usize, 0usize);
    for &c in sample {
        match c {
            b'A'..=b'Z' => u += 1,
            b'a'..=b'z' => l += 1,
            b'0'..=b'9' => d += 1,
            _ => {}
        }
    }
    let len = sample.len() as f64;
    u as f64 >= len * 0.2 && l as f64 >= len * 0.2 && d as f64 >= len * 0.05
}

/// Chunks of at most MAX_CHUNK bytes, each a run of whole units (see
/// `units`), cut at anchors. Chunks with no letter or digit are dropped.
fn split(text: &str) -> Vec<&str> {
    if text.len() <= MAX_CHUNK {
        return vec![text];
    }
    let mut out = Vec::new();
    let (mut from, mut to) = (0, 0);
    units(text, 0, 0, &mut |s, e| {
        if e - from > MAX_CHUNK && to > from {
            if to - from >= MIN_CHUNK {
                out.push(&text[from..to]);
                from = s;
            } else {
                // A runt (a heading before a long run) rides with the unit,
                // cut at its last word break that fits.
                let cut = floor_boundary(text, from + MAX_CHUNK);
                let cut = text[s..cut].rfind([' ', '\n']).map_or(cut, |i| s + i + 1);
                out.push(&text[from..cut]);
                from = cut;
            }
        }
        to = e;
        if to - from >= MIN_CHUNK && anchor(&text[s..e]) {
            out.push(&text[from..to]);
            from = e;
        }
    });
    if to > from {
        out.push(&text[from..to]);
    }
    out.retain(|t| !markup_only(t));
    out.iter_mut().for_each(|t| *t = t.trim());
    out
}

const SEPARATORS: [&str; 4] = ["\n\n", "\n", ". ", " "];

/// Hands `unit(start, end)` contiguous ranges of at most MAX_CHUNK bytes
/// covering `text`, in order: paragraphs, else lines, sentences, words, then
/// char-boundary cuts. Each unit keeps its trailing separator.
fn units(text: &str, base: usize, level: usize, unit: &mut impl FnMut(usize, usize)) {
    if text.len() <= MAX_CHUNK {
        return unit(base, base + text.len());
    }
    let mut at = base;
    match SEPARATORS.get(level) {
        Some(sep) => {
            for part in text.split_inclusive(*sep) {
                units(part, at, level + 1, unit);
                at += part.len();
            }
        }
        None => {
            for piece in hard_split(text, MAX_CHUNK) {
                unit(at, at + piece.len());
                at += piece.len();
            }
        }
    }
}

/// Content-defined cut: FNV-1a of the unit, with odds proportional to its
/// length (a 512-byte paragraph always anchors, a short line rarely).
fn anchor(unit: &str) -> bool {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in unit.trim().as_bytes() {
        h = (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3);
    }
    h % ANCHOR_SPAN < unit.len() as u64
}

fn floor_boundary(text: &str, mut i: usize) -> usize {
    while !text.is_char_boundary(i) {
        i -= 1;
    }
    i
}

/// Pieces of at most `max` bytes, cut at char boundaries.
fn hard_split(text: &str, max: usize) -> Vec<&str> {
    let mut out = Vec::new();
    let mut rest = text;
    while rest.len() > max {
        let mut cut = max;
        while cut > 0 && !rest.is_char_boundary(cut) {
            cut -= 1;
        }
        if cut == 0 {
            cut = rest.char_indices().nth(1).map_or(rest.len(), |(i, _)| i);
        }
        out.push(&rest[..cut]);
        rest = &rest[cut..];
    }
    out.push(rest);
    out
}

/// For the segmented-parse fuzz in `links`: (level, start, end, text) per
/// heading at `segment`, and whether the prefilter let `body` through.
#[cfg(test)]
pub fn heading_spans(body: &str, segment: usize) -> (Vec<(usize, usize, usize, String)>, bool) {
    let spans = headings_in(body, segment)
        .into_iter()
        .map(|h| (h.level, h.start, h.end, h.text))
        .collect();
    (spans, may_have_heading(body))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(content: &str) -> Vec<String> {
        chunk(content, "", "T").into_iter().map(|c| c.3).collect()
    }

    #[test]
    fn code_is_not_a_heading() {
        assert_eq!(paths("# T\n\n```\n# x\n```\n\n## N\n\nm"), ["T", "T > N"]);
    }

    #[test]
    fn heading_inside_a_quote_does_not_split() {
        assert_eq!(paths("a\n\n> # q\n> body"), ["T"]);
    }

    #[test]
    fn every_chunk_is_bounded() {
        let long = "x".repeat(10_000) + " " + &"é".repeat(5_000);
        for c in chunk(
            &format!("# {}\n\n{long}", "h".repeat(900)),
            &"f".repeat(900),
            "T",
        ) {
            assert!(c.0.len() <= MAX_CHUNK);
            assert!(c.1.len() <= MAX_CHUNK + MAX_PREFIX + 2);
            assert!(c.2.len() <= MAX_CHUNK + MAX_PREFIX + 2);
        }
    }

    #[test]
    fn setext_without_a_hash_is_found() {
        assert_eq!(paths("a\n\nS\n  ---\n\nb"), ["T", "T > S"]);
    }

    #[test]
    fn empty_body_and_blank_note() {
        assert!(chunk("", "", "T").is_empty());
        assert!(chunk("   \n\n", "", "T").is_empty());
    }
}
