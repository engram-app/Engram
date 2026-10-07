//! Link scanning for `Engram.Links.Parser`. Byte-for-byte the two regexes it
//! replaced, as hand scanners:
//!
//!   wiki:     (!?)\[\[([^\]\[]+?)\]\]
//!   markdown: (!?)\[([^\]\[]*+)\]\(((?:[^()]++|\([^()]*+\))*+)\)
//!
//! Each is leftmost and non-overlapping, like `Regex.scan`. Both are linear:
//! a match can only start at `[`, and a label or wiki body stops at the next
//! `[`, so no byte is scanned from more than a couple of starts. The regexes
//! needed possessive quantifiers to stay linear, and one missing `+` cost the
//! 2026-10-03 worker OOM.
//!
//! Code ranges come from pulldown-cmark (CommonMark), replacing the old
//! ```` ```...``` ````, `~~~...~~~` and `` `...` `` regexes, which missed
//! longer fences, indented code and multi-backtick spans. Frontmatter keeps
//! its regex.
use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag};
use regex::Regex;
use std::borrow::Cow;
use std::collections::HashSet;
use std::sync::OnceLock;

/// (position, kind, a_start, a_len, b_start, b_len). kind: 0 wiki, 1 wiki
/// embed, 2 markdown, 3 markdown embed. Wiki: a = body between the brackets.
/// Markdown: a = label, b = raw destination inside the parentheses.
pub type Raw = (usize, u8, usize, usize, usize, usize);

fn frontmatter_len(s: &str) -> usize {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re =
        RE.get_or_init(|| Regex::new(r"(?s)\A---[\s\x{180E}]*\n.*?\n---[\s\x{180E}]*\n").unwrap());
    re.find(s).map_or(0, |m| m.end())
}

/// Sorted, non-overlapping (start, end) byte ranges a link may not start in.
///
/// Parsed after the frontmatter, so a stray fence inside YAML cannot swallow
/// the note. Parsed in segments because pulldown-cmark keeps a node per
/// inline item for its whole input: ~36x the input on dense inline markdown,
/// 73x on code-heavy notes. One segment's tree is freed before the next.
///
/// A cut goes before a column-0 line that closes every open paragraph,
/// container and indented block (see `next_cut`), so the rest parses the
/// same alone, unless a fenced or raw-HTML block is still open.
/// pulldown-cmark itself says whether one is: an open block runs to the end
/// of the segment. A rejected cut is retried at twice the length, so the
/// total parse work stays linear.
fn excluded(s: &str, segment: usize) -> Vec<(usize, usize)> {
    let fm = frontmatter_len(s);
    let mut out = Vec::new();
    if fm > 0 {
        out.push((0, fm));
    }
    code_ranges(&s[fm..], fm, segment, &mut out);
    out
}

/// Every code span and code block in `body` as sorted (start, end) byte
/// ranges offset by `base`, parsed in segments (see `excluded`).
pub fn code_ranges(body: &str, base: usize, segment: usize, out: &mut Vec<(usize, usize)>) {
    if may_have_code(body) {
        segmented(
            body,
            segment,
            |s, at, ranges| segment_code_ranges(s, base + at, ranges),
            |mut ranges| out.append(&mut ranges),
        );
    }
}

/// A segment with no safe cut within this many bytes is cut at a line
/// anyway. pulldown-cmark's tree reaches 72x its input on some text (a
/// million `-` lines, setext runs, a long paragraph of `#tags`), and with
/// no safe cut that tree spanned the whole note.
/// ponytail: a forced cut can misread the one block it splits (a heading,
/// a code span); only text with no safe cut for 64 KB pays that.
const FORCE: usize = 128 * 1024;

/// Runs `visit(segment, offset, items)` over `body` in segments (see
/// `excluded`) and hands each accepted segment's items to `accept`, in
/// order. `visit` returns the start of a block that may still be open at the
/// segment's end, if any; its items are then dropped and the segment
/// retried, ending before that block when a cut may go there (one parse of
/// the bytes before it), else at twice the longest length tried.
pub fn segmented<T>(
    body: &str,
    segment: usize,
    mut visit: impl FnMut(&str, usize, &mut Vec<T>) -> Option<usize>,
    mut accept: impl FnMut(Vec<T>),
) {
    let mut start = 0;
    let mut want = segment;
    let mut longest = 0;
    while start < body.len() {
        let base = want.max(FORCE / 2);
        let reach = base.saturating_mul(2);
        let limit = start.saturating_add(reach);
        let (end, final_cut) = match next_cut(body, start.saturating_add(want), limit) {
            Some(c) if c - start <= reach => (c, false),
            None if body.len() - start <= reach => (body.len(), true),
            _ => (forced_cut(body, start + base), true),
        };
        let mut items = Vec::new();
        match visit(&body[start..end], start, &mut items) {
            Some(open) if !final_cut => {
                let before = open > 0
                    && end - start > longest
                    && next_cut(body, start + open, start + open) == Some(start + open);
                longest = longest.max(end - start);
                want = if before { open } else { 2 * longest };
            }
            _ => {
                accept(items);
                start = end;
                want = segment;
                longest = 0;
            }
        }
    }
}

/// The next line start within FORCE / 2 of `at`, else a char boundary at it.
fn forced_cut(body: &str, at: usize) -> usize {
    let at = (0..=at)
        .rev()
        .find(|&i| body.is_char_boundary(i))
        .unwrap_or(0);
    match body[at..].find('\n') {
        Some(i) if i < FORCE / 2 => at + i + 1,
        _ => at,
    }
}

/// A code span needs a backtick, a fence ``` or `~~~`, and indented code
/// four columns of indent: a tab or four spaces in a row. Without any of
/// them pulldown-cmark finds no code, and most notes skip it entirely.
fn may_have_code(s: &str) -> bool {
    s.contains(['`', '\t']) || s.contains("~~~") || s.contains("    ")
}

/// Pushes code ranges, offset by `base`. Returns the start of a fenced or
/// raw-HTML block that runs to the end of `s`, i.e. may still be open.
fn segment_code_ranges(s: &str, base: usize, out: &mut Vec<(usize, usize)>) -> Option<usize> {
    // pulldown-cmark 0.13.4 panics on some valid input (an unwrap in
    // parse.rs, e.g. "> - [x]: /u\n    \r"). Rustler would turn that into an
    // exception and the note could not be saved or indexed. Losing one
    // segment's code ranges is the lesser harm: its links and tags count.
    let mut ranges = Vec::new();
    let parsed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut open = None;
        for (event, r) in Parser::new_ext(s, Options::ENABLE_TABLES).into_offset_iter() {
            match event {
                Event::Code(_) => ranges.push((r.start + base, r.end + base)),
                Event::Start(Tag::CodeBlock(kind)) => {
                    ranges.push((r.start + base, r.end + base));
                    if matches!(kind, CodeBlockKind::Fenced(_)) && r.end == s.len() {
                        open = open.or(Some(r.start));
                    }
                }
                Event::Start(Tag::HtmlBlock) if r.end == s.len() => open = open.or(Some(r.start)),
                _ => {}
            }
        }
        open
    }));
    match parsed {
        Ok(open) => {
            out.append(&mut ranges);
            open
        }
        Err(_) => None,
    }
}

/// Start of the first line at or after `from`, and at or before `limit`,
/// that a cut may precede: one at column 0 that starts a list item, fence or
/// ATX heading (each ends any open paragraph), or any column-0 line after a
/// blank line. `limit` keeps a note with no cut at all linear: without it,
/// every forced segment rescanned the rest of the note (10 MB of blank
/// lines took 10 s).
fn next_cut(s: &str, from: usize, limit: usize) -> Option<usize> {
    let b = s.as_bytes();
    let mut pos = match from.checked_sub(1) {
        None => 0,
        Some(f) => f + b.get(f..)?.iter().position(|&c| c == b'\n')? + 1,
    };
    let mut prev_blank = false;
    while pos < b.len() && pos <= limit {
        let eol = b[pos..]
            .iter()
            .position(|&c| c == b'\n')
            .map_or(b.len(), |i| pos + i + 1);
        let line = &b[pos..eol];
        if pos > 0 && (prev_blank && !line[0].is_ascii_whitespace() || starts_block(line)) {
            return Some(pos);
        }
        prev_blank = line.iter().all(u8::is_ascii_whitespace);
        pos = eol;
    }
    None
}

fn starts_block(line: &[u8]) -> bool {
    // Under a table header, `- | -` is the delimiter row, not a list item.
    if line.contains(&b'|') {
        return false;
    }
    let hashes = line.iter().take_while(|&&c| c == b'#').count();
    let ticks = line.iter().take_while(|&&c| c == b'`').count();
    // An empty item cannot interrupt a paragraph; a backtick in a ``` info
    // string makes the line a code span instead.
    // pulldown-cmark also ends a line at a lone \r.
    matches!(line, [b'-' | b'*' | b'+', b' ', rest @ ..]
        if rest.iter().take_while(|&&c| c != b'\r' && c != b'\n').any(|c| !c.is_ascii_whitespace()))
        || ticks >= 3 && !line[ticks..].contains(&b'`')
        || line.starts_with(b"~~~")
        || (1..=6).contains(&hashes) && matches!(line.get(hashes), Some(b' ' | b'\n') | None)
}

/// Bytes per segment before `excluded` looks for a cut.
pub const SEGMENT: usize = 64 * 1024;

fn in_ranges(pos: usize, ranges: &[(usize, usize)]) -> bool {
    let i = ranges.partition_point(|&(_, end)| end <= pos);
    i < ranges.len() && ranges[i].0 <= pos
}

fn wiki_at(s: &[u8], j: usize) -> Option<(usize, usize)> {
    if s.get(j..j + 2)? != b"[[" {
        return None;
    }
    let body = j + 2;
    let mut k = body;
    while k < s.len() && s[k] != b']' && s[k] != b'[' {
        k += 1;
    }
    (k > body && s.get(k..k + 2)? == b"]]").then_some((k - body, k + 2))
}

/// (label_len, dest_start, dest_len, end) for a markdown link at `j`.
fn markdown_at(s: &[u8], j: usize) -> Option<(usize, usize, usize, usize)> {
    if *s.get(j)? != b'[' {
        return None;
    }
    let mut k = j + 1;
    while k < s.len() && s[k] != b']' && s[k] != b'[' {
        k += 1;
    }
    if s.get(k..k + 2)? != b"](" {
        return None;
    }
    let dest = k + 2;
    let mut p = dest;
    loop {
        match *s.get(p)? {
            b')' => return Some((k - j - 1, dest, p - dest, p + 1)),
            b'(' => {
                // One balanced level; a second `(` or no `)` fails the match.
                p += 1;
                while *s.get(p)? != b')' {
                    if s[p] == b'(' {
                        return None;
                    }
                    p += 1;
                }
                p += 1;
            }
            _ => p += 1,
        }
    }
}

fn scan(s: &[u8], out: &mut Vec<Raw>, markdown: bool) {
    let mut i = 0;
    while i < s.len() {
        let bang = s[i] == b'!';
        let j = i + bang as usize;
        let hit = if markdown {
            markdown_at(s, j).map(|(ll, ds, dl, end)| ((i, 2 + bang as u8, j + 1, ll, ds, dl), end))
        } else {
            wiki_at(s, j).map(|(bl, end)| ((i, bang as u8, j + 2, bl, 0, 0), end))
        };
        match hit {
            Some((raw, end)) => {
                out.push(raw);
                i = end;
            }
            None => i += 1,
        }
    }
}

/// One link, ready for `Links.Parser`: (position, kind, target_start,
/// target_len, target, alias, anchor). `target` is decoded for markdown
/// links; the raw target is `binary_part(content, target_start, target_len)`.
/// Strings borrow from the note unless decoding changed them.
pub type Link<'a> = (
    usize,
    u8,
    usize,
    usize,
    Cow<'a, str>,
    Option<&'a str>,
    Option<Cow<'a, str>>,
);

/// Links in position order, one per position, handed to `emit` one at a
/// time (the caller builds BEAM terms, so no Rust copy of the output
/// exists). Returns how many strings needed a UTF-8 scrub: a percent escape
/// can decode to invalid bytes, and the caller reports those. The rules are
/// `Links.Parser`'s, ported byte for byte and pinned by its golden set.
/// `limit` caps how many links are emitted: the first `limit` by
/// position, then the first occurrence of each target not yet emitted, up
/// to `limit` more. So every target keeps one edge (the rename rewrite
/// finds its source notes through stored edges, and backlinks need only
/// one), and the total stays under 2 x `limit`. Returns the scrub count and
/// whether any link was dropped.
pub fn extract<'a>(s: &'a str, limit: usize, mut emit: impl FnMut(Link<'a>)) -> (usize, bool) {
    let mut raw = matches(s);
    // Stable, so a wiki link wins a tie, as the Elixir sort did; ties are
    // resolved after dropping matches with no target. `note_links` is unique
    // on (source_note_id, position).
    raw.sort_by_key(|m| m.0);
    let mut scrubs = 0;
    let mut last = None;
    let mut targets: HashSet<String> = HashSet::new();
    let (mut emitted, mut extra, mut cut) = (0, 0, false);
    for m in raw {
        if last == Some(m.0) {
            continue;
        }
        let link = if m.1 < 2 {
            wiki_link(s, m)
        } else {
            markdown_link(s, m, &mut scrubs)
        };
        if let Some(link) = link {
            last = Some(m.0);
            let new_target = !targets.contains(link.4.as_ref());
            if emitted < limit || (new_target && extra < limit) {
                if emitted >= limit {
                    extra += 1;
                }
                if new_target {
                    targets.insert(link.4.to_string());
                }
                emitted += 1;
                emit(link);
            } else {
                cut = true;
                if extra >= limit {
                    break;
                }
            }
        }
    }
    (scrubs, cut)
}

/// `String.trim/1` and `str::trim` agree: both use Unicode White_Space.
fn clean(s: &str) -> Option<&str> {
    Some(s.trim()).filter(|t| !t.is_empty())
}

fn wiki_link(s: &str, (pos, kind, inner_start, inner_len, _, _): Raw) -> Option<Link<'_>> {
    let inner = &s[inner_start..inner_start + inner_len];
    let (body, alias) = match inner.split_once('|') {
        Some((b, a)) => (b, clean(a)),
        None => (inner, None),
    };
    let (target_raw, anchor) = match body.split_once('#') {
        Some((t, a)) => (t, clean(a).map(Cow::Borrowed)),
        None => (body, None),
    };
    let target = clean(target_raw)?;
    let lead = target_raw.len() - target_raw.trim_start().len();
    Some((
        pos,
        kind,
        inner_start + lead,
        target.len(),
        Cow::Borrowed(target),
        alias,
        anchor,
    ))
}

fn markdown_link<'a>(
    s: &'a str,
    (pos, kind, label_start, label_len, dest_start, dest_len): Raw,
    scrubs: &mut usize,
) -> Option<Link<'a>> {
    let b = s.as_bytes();
    let dest = &s[dest_start..dest_start + dest_len];
    // Trim, then the CommonMark destination: `<...>`, or up to whitespace.
    let mut start = dest_start + dest.len() - dest.trim_start().len();
    let mut len = dest.trim().len();
    if len >= 1 && b[start] == b'<' {
        if let Some(i) = b[start + 1..start + len].iter().position(|&c| c == b'>') {
            start += 1;
            len = i;
        }
    } else if let Some(i) = b[start..start + len]
        .iter()
        .position(|c| b" \t\n\r".contains(c))
    {
        len = i;
    }
    let mut anchor = None;
    if let Some(i) = b[start..start + len].iter().position(|&c| c == b'#') {
        let (a, scrubbed) = decode(&s[start + i + 1..start + len]);
        *scrubs += scrubbed as usize;
        anchor = match a {
            Cow::Borrowed(a) => clean(a).map(Cow::Borrowed),
            Cow::Owned(a) => clean(&a).map(|t| Cow::Owned(t.to_string())),
        };
        len = i;
    }
    let raw = &s[start..start + len];
    if len == 0 || external(raw) {
        return None;
    }
    let (target, scrubbed) = decode(raw);
    *scrubs += scrubbed as usize;
    Some((
        pos,
        kind,
        start,
        len,
        target,
        clean(&s[label_start..label_start + label_len]),
        anchor,
    ))
}

/// Percent-decode then scrub; borrowed when there is no `%` to decode.
fn decode(s: &str) -> (Cow<'_, str>, bool) {
    if !s.contains('%') {
        return (Cow::Borrowed(s), false);
    }
    let (out, scrubbed) = scrub(uri_decode(s.as_bytes()));
    (Cow::Owned(out), scrubbed)
}

/// `URI.decode/1`: `%` and two hex digits become a byte; any other `%` is
/// kept as written.
fn uri_decode(b: &[u8]) -> Vec<u8> {
    let hex = |c: u8| (c as char).to_digit(16).map(|d| d as u8);
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match (
            b[i],
            b.get(i + 1).copied().and_then(hex),
            b.get(i + 2).copied().and_then(hex),
        ) {
            (b'%', Some(h), Some(l)) => {
                out.push(h << 4 | l);
                i += 3;
            }
            (c, _, _) => {
                out.push(c);
                i += 1;
            }
        }
    }
    out
}

/// `Helpers.scrub_utf8/1`: one U+FFFD per invalid BYTE (not per maximal
/// subpart, as `String::from_utf8_lossy` does). True if anything changed.
fn scrub(b: Vec<u8>) -> (String, bool) {
    let mut rest = match String::from_utf8(b) {
        Ok(s) => return (s, false),
        Err(e) => e.into_bytes(),
    };
    let mut out = String::with_capacity(rest.len() + 2);
    loop {
        match std::str::from_utf8(&rest) {
            Ok(s) => {
                out.push_str(s);
                return (out, true);
            }
            Err(e) => {
                let ok = e.valid_up_to();
                out.push_str(std::str::from_utf8(&rest[..ok]).unwrap());
                out.push('\u{FFFD}');
                rest.drain(..ok + 1);
            }
        }
    }
}

/// `~r/\A(?:[a-z][a-z0-9+.\-]*:|\/\/)/i`: a scheme or protocol-relative URL.
/// That regex had no `u` flag, so its letters are ASCII only.
fn external(t: &str) -> bool {
    let b = t.as_bytes();
    if t.starts_with("//") {
        return true;
    }
    if !b.first().is_some_and(u8::is_ascii_alphabetic) {
        return false;
    }
    b.iter()
        .find(|&&c| !(c.is_ascii_alphanumeric() || matches!(c, b'+' | b'.' | b'-')))
        .is_some_and(|&c| c == b':')
}

/// Wiki matches then markdown matches, each in document order, minus any
/// starting in frontmatter or code.
fn matches(s: &str) -> Vec<Raw> {
    matches_segmented(s, SEGMENT)
}

fn matches_segmented(s: &str, segment: usize) -> Vec<Raw> {
    let ranges = excluded(s, segment);
    let mut out = Vec::new();
    scan(s.as_bytes(), &mut out, false);
    scan(s.as_bytes(), &mut out, true);
    out.retain(|m| !in_ranges(m.0, &ranges));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_stops_at_the_limit_and_says_so() {
        let note = "[[a]] [[b]] [[c]] [[d]]";
        let run = |limit| {
            let mut n = 0;
            let (_, cut) = extract(note, limit, |_| n += 1);
            (n, cut)
        };
        assert_eq!(run(usize::MAX), (4, false));
        assert_eq!(run(4), (4, false));
        // Past the limit, each new target still gets one edge (up to limit more).
        assert_eq!(run(3), (4, false));
        assert_eq!(run(2), (4, false));
        assert_eq!(run(1), (2, true));
        assert_eq!(extract("no links", 0, |_| ()), (0, false));
        // Repeats of one target past the limit are dropped, a new target is not.
        let note = format!("{}[[late]]", "[[a]] ".repeat(10));
        let mut got = Vec::new();
        let (_, cut) = extract(&note, 3, |l| got.push(l.4.to_string()));
        assert!(cut);
        assert_eq!(got, ["a", "a", "a", "late"]);
    }

    #[test]
    fn wiki_and_embed() {
        assert_eq!(
            matches("a ![[x|y]] [[z]]"),
            vec![(2, 1, 5, 3, 0, 0), (11, 0, 13, 1, 0, 0)]
        );
    }

    #[test]
    fn markdown_one_paren_level() {
        assert_eq!(matches("[l](My (f).md)"), vec![(0, 2, 1, 1, 4, 9)]);
        assert_eq!(matches("[l](a((b)).md)"), vec![]);
        assert_eq!(matches("[l](a(b.md"), vec![]);
    }

    #[test]
    fn code_is_excluded() {
        assert_eq!(
            matches("````\n[[a]]\n````\n``x [[b]] y``\n\n    [[c]]\n"),
            vec![]
        );
        assert_eq!(
            matches("```\n[[a]]"),
            vec![],
            "an unclosed fence runs to the end"
        );
    }

    #[test]
    fn frontmatter_is_excluded_and_does_not_open_a_fence() {
        assert_eq!(
            matches("---\nx: ```\n---\n[[a]]"),
            vec![(15, 0, 17, 1, 0, 0)]
        );
    }

    // Segmenting must never change a result. Cut as often as possible
    // (segment = 1) on generated markdown built from the constructs that
    // span lines: fences, lists, quotes, raw HTML, indents, code spans.
    #[test]
    fn segmented_equals_whole_document() {
        let pieces = [
            "```",
            "~~~",
            "````",
            "\n",
            "\n\n",
            "    ",
            "  ",
            "- ",
            "1. ",
            "> ",
            "`",
            "``",
            "[[a]]",
            "[l](b.md)",
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
            "text",
            "\t",
            "***",
            "---",
            "| a |",
            "|---|",
            "- | -",
            "a | b",
            "* | *",
            "*",
            "_",
            "\r",
            " ",
            "# ",
            "#",
            "+ ",
            "* ",
            "##",
            "1. x\n2. y",
            "foo\n",
            "===",
            "\n---\n",
            "  ---",
            "Title\n===\n",
            "[x]: /u",
        ];
        // CI runs 20k cases; the nightly (cron.yml) runs 2M per seed. Run it
        // deep after touching the cut rules or bumping pulldown-cmark:
        // ENGRAM_FUZZ_CASES=2000000 ENGRAM_FUZZ_SEED=7 cargo test --release segmented
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
                matches_segmented(&doc, 1),
                matches_segmented(&doc, usize::MAX),
                "{doc:?}"
            );
            // The chunker's heading pass rides the same segmenter.
            let (cut, passes) = crate::chunker::heading_spans(&doc, 1);
            let (whole, _) = crate::chunker::heading_spans(&doc, usize::MAX);
            assert_eq!(cut, whole, "headings {doc:?}");
            assert!(
                passes || whole.is_empty(),
                "may_have_heading missed {doc:?}"
            );
            if !may_have_code(&doc) {
                let mut ranges = Vec::new();
                segment_code_ranges(&doc, 0, &mut ranges);
                assert!(ranges.is_empty(), "may_have_code missed {doc:?}");
            }
        }
    }

    // pulldown-cmark 0.13 panics on this (an unwrap in parse.rs). The note
    // must still parse: its code ranges are dropped, never the whole call.
    #[test]
    fn a_pulldown_panic_does_not_fail_the_parse() {
        assert_eq!(
            matches("> - [x]: /u\n    \r [[a]]"),
            matches("> - [x]: /u\n    \r [[a]]")
        );
        assert_eq!(matches("#t\n\n> - [x]: /u\n    \r").len(), 0);
        assert_eq!(matches("[[z]]\n\n> - [x]: /u\n    \r").len(), 1);
    }

    // `- | -` under a table header is the delimiter row, not a list item:
    // a cut there turned the next row's cells into one code span.
    #[test]
    fn no_cut_inside_a_table() {
        let doc = "a | b\n- | -\n`c | [[d]]`\n";
        assert_eq!(
            matches_segmented(doc, 1),
            matches_segmented(doc, usize::MAX)
        );
        assert_eq!(matches_segmented(doc, 1).len(), 1);
    }

    // The old regex ran without `u`: ASCII letters only.
    #[test]
    fn only_ascii_schemes_are_external() {
        assert!(external("https:x") && external("//cdn"));
        assert!(!external("\u{17F}:x.md") && !external("\u{212A}a:y.md"));
    }

    // The old frontmatter regex had `u`, where PCRE's `\s` includes U+180E.
    #[test]
    fn frontmatter_whitespace_includes_u180e() {
        assert_eq!(matches("---\u{180E}\n[[a]]\n---\n"), vec![]);
    }

    #[test]
    fn linear_on_bracket_runs() {
        let s = "[".repeat(1_000_000) + &"(".repeat(1_000_000);
        // Min of 3, so a parallel test's load spike cannot fail it (~30 ms
        // typical). A quadratic scan of 2 MB is minutes: the wide limit only
        // trips on that, never on a slow runner.
        let best = (0..3)
            .map(|_| {
                let t = std::time::Instant::now();
                assert_eq!(matches(&s), vec![]);
                t.elapsed()
            })
            .min()
            .unwrap();
        assert!(best.as_secs() < 5, "{best:?}");
    }
}
