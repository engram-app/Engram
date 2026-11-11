//! Note title and tags for `Engram.Notes.Helpers`, ported rule for rule from
//! its regexes and pinned by its golden set. Deliberately not a YAML parser:
//! one syntax error anywhere would fail the whole block, where these rules
//! read `title:`/`tags:` lines and keep every tag they can.
//!
//! The one change: the H1 title and inline `#tags` skip CommonMark code
//! ranges (pulldown-cmark, as for links) instead of the old ```` ``` ````,
//! `~~~` and `` ` `` regexes.
use crate::links::{code_ranges, SEGMENT};
use std::borrow::Cow;
use std::collections::HashSet;
use unicode_segmentation::UnicodeSegmentation;

// The Elixir regexes without the `u` flag ran in byte mode, where `\s` and
// `\d` are ASCII only.
const ASCII_WS: &str = r"[\t\n\x0B\x0C\r ]";

/// (frontmatter block without its last line break, body start), by the
/// shared fence rule after a BOM (`engram_core::frontmatter`). The old
/// `\A---\r?\n(.*?)\r?\n---` also closed on `---foo` and `----`.
fn frontmatter(s: &str) -> Option<(&str, usize)> {
    let (start, end, body, _) = crate::frontmatter::split_after_bom(s.as_bytes())?;
    let block = &s[start..end];
    Some((block.strip_suffix('\r').unwrap_or(block), body))
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
            if seen.len() == MAX_TAGS {
                break;
            }
        }
    }
}

/// Most distinct tags kept per note (frontmatter first, then inline in
/// order). Each is stored on the note and copied into every Qdrant point's
/// payload, so the count, not the note size, sets that cost; the rest of the
/// note indexes and searches in full.
pub const MAX_TAGS: usize = 1_000;

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
    /// Golden-set rows whose embedded chunks move (see the test below).
    const GOLDEN_CHANGED: usize = 8;

    // Every distinct tag is stored on the note and copied into each Qdrant
    // point's payload (x64 per upsert batch): 8 MB of unique `#tN` was 1.16M
    // tags, ~55 MB of filter hashes PER POINT. Real notes have tens.
    #[test]
    fn tags_stop_at_the_cap_frontmatter_first() {
        let body: String = (0..5_000).map(|i| format!("#t{i} ")).collect();
        let mut got = Vec::new();
        super::title_and_tags(&format!("---\ntags: [fm]\n---\n{body}"), |t| {
            got.push(t.to_string())
        });
        assert_eq!(got.len(), super::MAX_TAGS);
        assert_eq!((got[0].as_str(), got[1].as_str()), ("fm", "t0"));
        // Repeats do not spend the cap.
        let mut n = 0;
        super::title_and_tags(&"#same ".repeat(10_000), |_| n += 1);
        assert_eq!(n, 1);
    }

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

    // #1884 merge gate: the shared fence rule moves no embedded chunk text
    // on normal notes. The chunk path (`Markdown.parse/3`) takes two
    // fence-derived inputs: the body split (`frontmatter::parts` in
    // `chunker.rs` Job::new) and the title (`Native.note_title`, this
    // module), which is the breadcrumb prefix of every embedded string.
    // Fingerprints are computed in Elixir from the chunk tuple, so equal
    // chunks mean equal fingerprints. Old rules frozen from origin/main.
    mod old {
        /// origin/main `frontmatter.rs` split (the chunker's).
        pub fn split(s: &[u8]) -> crate::frontmatter::Split {
            let open = |s: &[u8]| {
                if s.starts_with(b"---\r\n") {
                    Some(5)
                } else if s.starts_with(b"---\n") {
                    Some(4)
                } else {
                    None
                }
            };
            let start = open(s)?;
            let rest = &s[start..];
            if let Some(n) = open(rest) {
                return Some((start, start, start + n, false));
            }
            if let Some(m) = re!(bytes r"\n---[ \t]*\r?\n").find(rest) {
                return Some((start, start + m.start(), start + m.end(), true));
            }
            re!(bytes r"\n---[ \t]*\r?\z")
                .find(rest)
                .map(|m| (start, start + m.start(), s.len(), true))
        }

        /// origin/main `meta.rs:28` title.
        pub fn title(s: &str) -> Option<String> {
            let fm = re!(r"(?s)\A---\r?\n(.*?)\r?\n---")
                .captures(s)
                .map(|c| (c.get(1).unwrap().as_str(), c.get(0).unwrap().end()));
            if let Some(t) = fm.and_then(|(fm, _)| super::super::fm_title(fm)) {
                return Some(t);
            }
            let body = &s[fm.map_or(0, |f| f.1)..];
            super::super::heading_title(body, &super::super::code_of(body))
        }
    }

    // `Markdown.parse/3` before the NIF: CRLF to LF, one leading BOM dropped.
    fn normalise(s: &str) -> String {
        let s = s.replace("\r\n", "\n");
        s.strip_prefix('\u{FEFF}').unwrap_or(&s).to_string()
    }

    fn chunks(content: &str, title: Option<String>) -> Vec<crate::chunker::Chunk> {
        let mut out = Vec::new();
        let title = title.unwrap_or_default();
        crate::chunker::each_chunk(content, "", &title, &[], None, false, &mut out);
        out
    }

    #[test]
    fn the_fence_rule_moves_no_embedded_chunk_on_normal_notes() {
        let normal = [
            "# Plain note\n\nSome text with a [[link]] and #tag.\n",
            "---\ntitle: Weekly review\ntags: [work]\n---\n# Weekly review\n\n## Done\n\n- a\n- b\n",
            "---\r\ntitle: Windows note\r\n---\r\nBody line\r\n",
            "\u{FEFF}---\ntitle: BOM note\n---\n# H\n\ntext\n",
            "---\naliases: [x]\n---\n\n```\n# not a title\n```\n# Real\n",
            "---\ntitle: Only frontmatter\n---",
            "---\n---\nEmpty block then body\n",
            "No frontmatter at all\n\n---\n\nA thematic break above.\n",
        ];
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../engram_core/fixtures/frontmatter_fence.json"
        ))
        .unwrap();
        let golden: serde_json::Value = serde_json::from_str(include_str!(
            "../../../test/support/fixtures/note_meta_golden.json"
        ))
        .unwrap();
        let mut corpus: Vec<(String, String)> = normal
            .iter()
            .enumerate()
            .map(|(i, s)| (format!("normal {i}"), s.to_string()))
            .collect();
        for c in fixture.as_array().unwrap() {
            let name = format!("fixture {}", c["name"].as_str().unwrap());
            corpus.push((name, c["input"].as_str().unwrap().to_string()));
        }
        for (i, c) in golden.as_array().unwrap().iter().enumerate() {
            corpus.push((
                format!("golden {i}"),
                c["input"].as_str().unwrap().to_string(),
            ));
        }

        let mut changed = Vec::new();
        for (name, raw) in &corpus {
            let s = normalise(raw);
            // The body split the chunker uses is unchanged on every row.
            assert_eq!(
                crate::frontmatter::split(s.as_bytes()),
                old::split(s.as_bytes()),
                "{name}"
            );
            if chunks(&s, super::title(&s)) != chunks(&s, old::title(&s)) {
                // A changed title means the old regex closed on a fence line
                // the shared rule rejects: `---` then something non-blank.
                let close = re!(r"(?s)\A---\r?\n.*?\r?\n---([^\n]*)")
                    .captures(&s)
                    .map(|c| c[1].to_string());
                assert!(
                    close
                        .as_deref()
                        .is_some_and(|t| !t.trim_matches([' ', '\t']).is_empty()),
                    "{name}: {s:?}"
                );
                changed.push(name.as_str());
            }
        }
        // Every changed row is a frontmatter closed by a line that is `---`
        // plus non-blank text (`---foo`, `----`, `---` U+180E): the old
        // title regex closed there, the shared rule does not, so the title
        // (the embedded breadcrumb prefix) moves. No normal note moves.
        assert!(
            changed.iter().all(|n| !n.starts_with("normal")),
            "{changed:?}"
        );
        assert_eq!(
            changed
                .iter()
                .filter(|n| n.starts_with("fixture"))
                .copied()
                .collect::<Vec<_>>(),
            [
                "fixture close_with_suffix_is_not_a_close",
                "fixture four_dashes_is_not_a_close",
                "fixture u180e_after_close_is_not_a_close",
            ]
        );
        assert_eq!(changed.len(), 3 + GOLDEN_CHANGED, "{changed:?}");
    }
}
