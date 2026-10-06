//! Note title and tags for `Engram.Notes.Helpers`, ported rule for rule from
//! its regexes and pinned by its golden set. Deliberately not a YAML parser:
//! one syntax error anywhere would fail the whole block, where these rules
//! read `title:`/`tags:` lines and keep every tag they can.
//!
//! The one change: the H1 title and inline `#tags` skip CommonMark code
//! ranges (pulldown-cmark, as for links) instead of the old ```` ``` ````,
//! `~~~` and `` ` `` regexes.
use crate::links::{code_ranges, SEGMENT};
use regex::Regex;
use std::borrow::Cow;
use std::collections::HashSet;
use std::sync::OnceLock;
use unicode_segmentation::UnicodeSegmentation;

macro_rules! re {
    ($pat:expr) => {{
        static RE: OnceLock<Regex> = OnceLock::new();
        RE.get_or_init(|| Regex::new($pat).unwrap())
    }};
}

// The Elixir regexes without the `u` flag ran in byte mode, where `\s` and
// `\d` are ASCII only.
const ASCII_WS: &str = r"[\t\n\x0B\x0C\r ]";

/// `~r/\A---\r?\n(.*?)\r?\n---/s`: (frontmatter body, end of the match).
fn frontmatter(s: &str) -> Option<(&str, usize)> {
    let c = re!(r"(?s)\A---\r?\n(.*?)\r?\n---").captures(s)?;
    Some((c.get(1)?.as_str(), c.get(0)?.end()))
}

/// Frontmatter `title:`, else the first `# heading` outside code. The
/// caller falls back to the file name.
pub fn title(s: &str) -> Option<String> {
    let fm = frontmatter(s);
    if let Some(t) = fm.and_then(|(fm, _)| fm_title(fm)) {
        return Some(t);
    }
    let body = body_of(s, fm);
    heading_title(body, &code_of(body))
}

/// `title`, plus frontmatter tags then inline `#tags` outside code (first
/// occurrence kept), handed to `emit` one at a time (the caller builds BEAM
/// terms, so inline tags are never copied into Rust strings). The
/// frontmatter match and the code ranges (the costly part) are computed
/// once for both.
pub fn title_and_tags(s: &str, emit: impl FnMut(&str)) -> Option<String> {
    let fm = frontmatter(s);
    let body = body_of(s, fm);
    let code = code_of(body);
    let title = fm
        .and_then(|(fm, _)| fm_title(fm))
        .or_else(|| heading_title(body, &code));
    emit_tags(fm, body, &code, emit);
    title
}

fn body_of<'a>(s: &'a str, fm: Option<(&str, usize)>) -> &'a str {
    &s[fm.map_or(0, |f| f.1)..]
}

/// CommonMark code ranges of the body; none needed without a `#`.
fn code_of(body: &str) -> Vec<(usize, usize)> {
    let mut code = Vec::new();
    if body.contains('#') {
        code_ranges(body, 0, SEGMENT, &mut code);
    }
    code
}

fn fm_title(fm: &str) -> Option<String> {
    let title_re = re!(&format!(r"(?m)^title:{ASCII_WS}*(.+)$"));
    title_re.captures(fm).map(|c| c[1].trim().to_string())
}

fn heading_title(body: &str, code: &[(usize, usize)]) -> Option<String> {
    if !body.contains('#') {
        return None;
    }
    let heading_re = re!(&format!(r"(?m)^#{ASCII_WS}+(.+)$"));
    let mut pos = 0;
    while let Some(c) = heading_re.captures_at(body, pos) {
        let start = c.get(0)?.start();
        // The first range ending after `start`; matches only move forward.
        let i = code.partition_point(|&(_, end)| end <= start);
        match code.get(i) {
            Some(&(s, end)) if s <= start => pos = end,
            _ => return Some(c[1].trim().to_string()),
        }
    }
    None
}

fn emit_tags(
    fm: Option<(&str, usize)>,
    body: &str,
    code: &[(usize, usize)],
    mut emit: impl FnMut(&str),
) {
    let fm_tags = fm.map(|(fm, _)| frontmatter_tags(fm)).unwrap_or_default();
    // A code range reads as one space, so a word before it cannot fuse onto
    // a `#tag` after it.
    let stripped: Cow<str> = if code.is_empty() {
        Cow::Borrowed(body)
    } else {
        let mut out = String::with_capacity(body.len());
        let mut at = 0;
        for &(start, end) in code {
            out.push_str(&body[at..start]);
            out.push(' ');
            at = end;
        }
        out.push_str(&body[at..]);
        Cow::Owned(out)
    };
    let mut seen = HashSet::new();
    for t in fm_tags
        .iter()
        .map(String::as_str)
        .chain(inline_tags(&stripped))
    {
        if seen.insert(t) {
            emit(t);
        }
    }
}

/// `#tag` or nested `#area/sub`, after start-of-text or whitespace (so
/// `word#x` and `https://h/#frag` are not tags), starting with a word char
/// (so `# heading` is not one). Matching is per codepoint: the old byte-mode
/// regex split `#628–` into `628` plus a lone 0xE2 byte, the invalid-UTF-8
/// tags found at rest in prod (#741). PCRE's Unicode `\w` is \p{L}, \p{N}
/// and `_`; its `\s` also has U+180E.
///
/// `find_iter` plus a look at the preceding char, not a capture group: a
/// capture allocates per match. Same matches, since a tag never ends on the
/// whitespace the next one needs.
fn inline_tags(s: &str) -> impl Iterator<Item = &str> {
    re!(r"#[\p{L}\p{N}_][\p{L}\p{N}_/-]*")
        .find_iter(s)
        .filter(|m| {
            s[..m.start()]
                .chars()
                .next_back()
                .is_none_or(|c| c.is_whitespace() || c == '\u{180E}')
        })
        .map(|m| m.as_str()[1..].trim_end_matches(['/', '-']))
        .filter(|t| !t.is_empty() && !t.bytes().all(|b| b.is_ascii_digit() || b"/_-".contains(&b)))
}

fn frontmatter_tags(fm: &str) -> Vec<String> {
    // Block list: a bare `tags:` line, then `  - item` lines.
    if let Some(c) = re!(r"(?ms)^tags:[ \t]*\r?\n(.*)").captures(fm) {
        let item_re = re!(&format!(r"\A{ASCII_WS}*-{ASCII_WS}+"));
        let items: Vec<String> = c[1]
            .split('\n')
            .take_while(|l| item_re.is_match(l))
            .map(|l| tag_item(&item_re.replace(l, "")))
            .filter(|t| !t.is_empty())
            .collect();
        if !items.is_empty() {
            return items;
        }
    }
    // Inline value on the `tags:` line: `[a, b]` or `a, b`.
    let inline_re = re!(r"(?m)^tags:[ \t]*([^\t\n\x0B\x0C\r ].*)$");
    let Some(c) = inline_re.captures(fm) else {
        return Vec::new();
    };
    let v = c[1].trim();
    if v == "[]" {
        return Vec::new();
    }
    let list = v
        .strip_prefix('[')
        .map_or(v, |rest| rest.trim_end_matches(']'));
    list.split(',')
        .map(tag_item)
        .filter(|t| !t.is_empty())
        .collect()
}

/// One tag, or "" for a scalar YAML would not read as a string: `tags: true`
/// must not invent a tag named "true".
///
/// Rules, not a YAML parser. YamlElixir cost ~2.6 ms per call and this runs
/// per tag per write. Two earlier hand-written attempts were wrong in both
/// directions (`tRue`, `nUll`, `1_000`, `1/2` are strings; `0x10`, `1e5`,
/// `+1`, `.5`, `0o17`, `.inf` are not), so `helpers_test.exs` pins these
/// rules against YamlElixir. YAML 1.2 core: no `1_000`, no yes/no/on/off.
///
/// Fails open: a scalar nothing recognises is kept, because refusing to guess
/// must never cost the user a tag. Quoted text is always a tag (`"true"` is
/// a user asking for one). Deliberately looser than the inline numeric rule,
/// which drops `1/2` and `2024-01-02` though YAML reads them as strings.
fn tag_item(raw: &str) -> String {
    let trimmed = raw.trim();
    if !trimmed.starts_with(['"', '\'']) && non_string_scalar(trimmed) {
        return String::new();
    }
    unquote(trimmed)
}

/// Drops matching surrounding quotes, counted in graphemes as Elixir's
/// `String.length/1` and `String.slice/3` do.
fn unquote(s: &str) -> String {
    let g: Vec<&str> = s.graphemes(true).collect();
    let quoted = |q: char| s.starts_with(q) && s.ends_with(q);
    if g.len() >= 2 && (quoted('"') || quoted('\'')) {
        g[1..g.len() - 1].concat()
    } else {
        s.to_string()
    }
}

fn non_string_scalar(item: &str) -> bool {
    matches!(item, "true" | "True" | "TRUE" | "false" | "False" | "FALSE" | "null" | "Null" | "NULL" | "~")
        || re!(concat!(
            r"\A(?:[-+]?[0-9]+|0o[0-7]+|0x[0-9a-fA-F]+|[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?",
            r"|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))\z"
        ))
        .is_match(item)
}

#[cfg(test)]
mod tests {
    // Skipping a heading inside code must not rescan the code ranges from
    // the start: 480 KB of code-fenced `# x` lines took 1.3 s.
    #[test]
    fn title_is_linear_past_many_code_headings() {
        // 1.9 MB: the quadratic bug takes ~20 s here, linear well under
        // 300 ms, so the 3 s limit only trips on the quadratic. Min of 3:
        // cargo runs tests on parallel threads, so one sample can eat a load
        // spike.
        let s = "```\n# x\n```\n".repeat(160_000) + "# Real\n";
        let best = (0..3)
            .map(|_| {
                let t = std::time::Instant::now();
                assert_eq!(super::title(&s).as_deref(), Some("Real"));
                t.elapsed()
            })
            .min()
            .unwrap();
        assert!(best.as_secs() < 3, "{best:?}");
    }
}
