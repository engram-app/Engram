//! `Engram.Parsers.Markdown.parse/2` in Rust: heading sections, base64 blob
//! stripping, word and hard splits, and the size caps. The Elixir side keeps
//! CRLF normalisation, the folder, the title and the frontmatter split (that
//! codec is shared with sync) and assigns positions.
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

/// One chunk: (text, context_text, heading_path, char_start, char_end).
pub type Chunk = (String, String, String, usize, usize);

struct Section<'a> {
    /// (level, heading text)
    stack: Vec<(usize, &'a str)>,
    start: usize,
    end: usize,
}

/// Chunks of a note. `body` is the post-frontmatter text, `block` the raw
/// frontmatter (None or empty: no frontmatter chunk).
pub fn chunk(body: &str, block: Option<&str>, folder: &str, title: &str) -> Vec<Chunk> {
    let mut out = Vec::new();
    if !body.trim().is_empty() {
        for s in sections(body) {
            let text = strip_blobs(&body[s.start..s.end]);
            let text = text.trim();
            if markup_only(text) {
                continue;
            }
            let heading_path = heading_path(title, &s.stack);
            let prefix = context_prefix(folder, &heading_path);
            let subs = if text.len() > MAX_CHUNK {
                split_text(text, MAX_CHUNK)
            } else {
                vec![text.to_string()]
            };
            for sub in subs {
                let context_text = format!("{prefix}\n\n{sub}");
                out.push((sub, context_text, heading_path.clone(), s.start, s.end));
            }
        }
    }
    if let Some(block) = block.filter(|b| !b.is_empty()) {
        let text = strip_blobs(block).into_owned();
        let prefix = context_prefix(folder, &format!("{title} > frontmatter"));
        out.push((
            text.clone(),
            format!("{prefix}\n\n{text}"),
            "frontmatter".into(),
            0,
            0,
        ));
    }
    out.into_iter().flat_map(enforce_size_cap).collect()
}

/// `^(#{1,6})\s+(.+)$` on one line, `\s` ASCII as in the byte-mode regex.
fn atx(line: &str) -> Option<(usize, &str)> {
    let c = re!(r"\A(#{1,6})[\t\n\x0B\x0C\r ]+(.+)\z").captures(line)?;
    Some((c.get(1)?.len(), c.get(2)?.as_str()))
}

fn sections(body: &str) -> Vec<Section<'_>> {
    let mut done = Vec::new();
    let mut cur = Section {
        stack: Vec::new(),
        start: 0,
        end: 0,
    };
    let mut pos = 0;
    for line in body.split('\n') {
        if let Some((level, text)) = atx(line) {
            let mut stack: Vec<_> = cur
                .stack
                .iter()
                .copied()
                .filter(|&(l, _)| l < level)
                .collect();
            stack.push((level, text));
            let next = Section {
                stack,
                start: pos,
                end: 0,
            };
            let prev = std::mem::replace(&mut cur, next);
            // A section is kept only if it holds non-blank text.
            if pos > 0 && !body[prev.start..pos - 1].trim().is_empty() {
                done.push(Section {
                    end: pos - 1,
                    ..prev
                });
            }
        }
        pos += line.len() + 1;
    }
    if !body[cur.start..].trim().is_empty() {
        done.push(Section {
            end: body.len(),
            ..cur
        });
    }
    done
}

fn heading_path(title: &str, stack: &[(usize, &str)]) -> String {
    let rest = match stack.first() {
        Some(&(1, _)) => &stack[1..],
        _ => stack,
    };
    let mut path = title.to_string();
    for (_, h) in rest {
        path.push_str(" > ");
        path.push_str(h);
    }
    path
}

fn context_prefix(folder: &str, heading_path: &str) -> String {
    if folder.is_empty() {
        heading_path.to_string()
    } else {
        format!("{folder} > {heading_path}")
    }
}

/// A section with no letter or digit carried only a blob and its markup.
fn markup_only(text: &str) -> bool {
    !re!(r"[\p{L}\p{N}]").is_match(text)
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

/// Greedy word packing. A word that alone overflows is cut with the text
/// before it, so no runt is stranded.
fn split_text(text: &str, max: usize) -> Vec<String> {
    let mut done: Vec<String> = Vec::new();
    let mut acc = String::new();
    for word in text.split(' ') {
        let candidate = if acc.is_empty() {
            word.to_string()
        } else {
            format!("{acc} {word}")
        };
        if candidate.len() <= max {
            acc = candidate;
        } else if word.len() > max {
            let mut pieces = hard_split(&candidate, max);
            acc = pieces.pop().unwrap_or_default();
            done.extend(pieces);
        } else {
            done.push(std::mem::replace(&mut acc, word.to_string()));
        }
    }
    if !acc.is_empty() {
        done.push(acc);
    }
    done
}

/// Pieces of at most `max` bytes, cut at char boundaries.
fn hard_split(text: &str, max: usize) -> Vec<String> {
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
        out.push(rest[..cut].to_string());
        rest = &rest[cut..];
    }
    out.push(rest.to_string());
    out
}

/// Voyage rejects an oversized input with a permanent 400, so EVERY chunk's
/// context_text is bounded here: text to MAX_CHUNK, prefix to MAX_PREFIX.
fn enforce_size_cap(c: Chunk) -> Vec<Chunk> {
    let (text, ctx, hp, s, e) = c;
    if text.len() <= MAX_CHUNK && ctx.len() - text.len() <= MAX_PREFIX {
        return vec![(text, ctx, hp, s, e)];
    }
    let prefix = if ctx.ends_with(&text) {
        &ctx[..ctx.len() - text.len()]
    } else {
        ""
    };
    let prefix = if prefix.len() <= MAX_PREFIX {
        prefix.to_string()
    } else {
        hard_split(prefix, MAX_PREFIX).swap_remove(0) + "\n\n"
    };
    hard_split(&text, MAX_CHUNK)
        .into_iter()
        .map(|t| (t.clone(), format!("{prefix}{t}"), hp.clone(), s, e))
        .collect()
}
