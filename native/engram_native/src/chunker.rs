//! `Engram.Parsers.Markdown.parse/2` in Rust (chunker version 4): the
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
/// Sections under this many bytes join their neighbours (min512, v5): a
/// tiny section alone is a weak dense vector and a wasted point.
const MIN_CHUNK: usize = 512;
/// An oversized section is cut after a unit whose hash beats every other
/// unit ending within WINDOW bytes either side (a local maximum). A cut
/// depends only on the text within WINDOW of it, so an edit or a deleted
/// paragraph re-chunks only its neighbourhood and the rest of the note keeps
/// its embeddings (#1594). Cuts are at least WINDOW apart; a gap over
/// MAX_CHUNK is packed greedily, which stays local to that gap.
const WINDOW: usize = 1024;
/// A forced cut never leaves a piece this small: it rides with the next unit.
const RUNT: usize = 512;

/// One chunk: (text, context_text, embed_text, heading_path, char_start,
/// char_end, kind). context_text carries the folder for keyword search
/// (#1615); embed_text, the dense input, drops it (#1621). The 4th element
/// is (heading path, members): the path is a list, title first (a heading
/// may itself contain ` > `), and members counts the sections a min512
/// chunk joins (1 when it joins none), so keyword scoring can treat merged
/// chunks apart (plan Task 14.1). kind is `prose`, `data`, `frontmatter`,
/// `frontmatter_dense` or `drawing`: only prose and frontmatter_dense get
/// a dense vector. (Rustler encodes tuples of at most 7.)
pub type Chunk = (
    String,
    String,
    String,
    (Vec<String>, u16),
    usize,
    usize,
    &'static str,
);

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
    each_chunk(content, folder, title, &[], None, |c| out.push(c));
    out
}

/// Most chunks a body of `len` bytes may produce before its tiny sections
/// coalesce: 2,000, or one per 512 bytes. Prose splits at >= WINDOW, so only
/// a note of tiny sections passes it (10 MB of `# h\nx\n` was 1.7M chunks:
/// 466 MB of terms and ~13k Voyage calls). Notes under it chunk exactly as
/// before, so their embeddings do not move.
fn budget(len: usize) -> usize {
    2_000.max(len / RUNT)
}

/// 2,000 sections need at least this much body (`# h\nx\n` is 6 bytes):
/// below it the count pass is skipped.
const COUNT_FROM: usize = 16 * 1024;

/// `chunk`, handing each chunk to `emit` as it is made, so a huge note's
/// chunks are never all held in Rust at once. Headings stream in segment by
/// segment, so they are not all held either. A body that would pass
/// `budget` is chunked again with its small sections coalesced.
/// `aliases` (from the frontmatter, cleaned by the caller) follow the title
/// in every prefix: `Title (aka A, B) > H1`. `lead` (`Type: description`,
/// one line, built by the caller) is a line after the prefix of the first
/// chunk only, in its dense and keyword inputs; it is not note text and
/// does not count toward MAX_CHUNK.
pub fn each_chunk(
    content: &str,
    folder: &str,
    title: &str,
    aliases: &[String],
    lead: Option<&str>,
    mut emit: impl FnMut(Chunk),
) {
    // The lead is for Voyage: it goes on the first chunk with a dense input,
    // not on a leading data or query block (review M4). Capped: an
    // over-length input is a permanent Voyage 400.
    let mut lead = lead.filter(|l| !l.is_empty()).map(|l| cut(l, MAX_LEAD));
    let prose_seen = std::cell::Cell::new(false);
    let mut emit = |mut c: Chunk| {
        let dense = c.6 == PROSE || c.6 == FRONTMATTER_DENSE;
        prose_seen.set(prose_seen.get() || c.6 == PROSE);
        if let Some(l) = lead.filter(|_| dense) {
            c.1 = with_lead(&c.1, l);
            c.2 = with_lead(&c.2, l);
            lead = None;
        }
        emit(c)
    };
    // A BOM before the fence still opens frontmatter here. Only for chunking:
    // the shared splitter (CRDT ingest, normalize) keeps its byte contract.
    let content = content.strip_prefix('\u{FEFF}').unwrap_or(content);
    let (block, body) = crate::frontmatter::parts(content);
    let body = &*excalidraw(block.as_deref(), body);
    let note = Note::new(folder, title, aliases);
    let coalesce = body.len() >= COUNT_FROM && {
        let mut n = 0;
        chunk_body(body, &note, false, &mut |_| n += 1);
        n > budget(body.len())
    };
    let emitted = chunk_body(body, &note, coalesce, &mut emit);
    // Every section was a bare heading (a stub, a daily-note template): keep
    // the headings as one chunk, or search could not find the note at all.
    if !emitted {
        let rest = strip_blobs(body);
        if !markup_only(&rest) {
            let path = [note.title.to_string()];
            for (t, kind) in classified(split(&normalize("", &rest))) {
                emit(make(&note, &path, t, 0, body.len(), kind));
            }
        }
    }
    // A note with no prose (properties alone, B8, or only data and query
    // blocks, review M5): its first frontmatter chunk gets a small dense
    // input, the head and the property values, or a search by meaning could
    // never reach it. Its keyword input stays the raw block.
    let mut dense = !prose_seen.get();
    if let Some(block) = block.filter(|b| !b.is_empty()) {
        let text = normalize("", &strip_blobs(&block));
        let path = [note.title.to_string(), "frontmatter".to_string()];
        for t in word_split(&text, MAX_CHUNK)
            .into_iter()
            .filter(|t| !t.is_empty())
        {
            let mut c = make(&note, &path, t, 0, 0, "frontmatter");
            c.3 = (vec!["frontmatter".to_string()], 1);
            if std::mem::take(&mut dense) {
                c.2 = match props(&block) {
                    v if v.is_empty() => note.head.clone(),
                    v => format!("{}\n\n{v}", note.head),
                };
                c.6 = FRONTMATTER_DENSE;
            }
            emit(c);
        }
    }
}

/// What every chunk of a note shares.
struct Note<'a> {
    folder: &'a str,
    title: &'a str,
    /// The title as heading text reads (`clean_heading`), to spot the H1
    /// that is the title: `# my_note` in `my_note.md` (review L1).
    title_text: String,
    /// The title and its aliases, `Title (aka A, B)`: the prefix head.
    head: String,
}

/// Most bytes of the lead line (`Type: description`).
const MAX_LEAD: usize = 256;

/// Most chars of the alias part (validation W8: uncapped, a long list
/// pushed the headings out of the prefix).
const MAX_AKA: usize = 200;

impl<'a> Note<'a> {
    fn new(folder: &'a str, title: &'a str, aliases: &[String]) -> Self {
        // Capped as heading text is, so the H1 that is the title still
        // matches it, and every heading path element is bounded.
        let title = cut(title, MAX_PREFIX);
        let aka = aliases.join(", ");
        let head = match aka.char_indices().nth(MAX_AKA) {
            _ if aka.is_empty() => title.to_string(),
            Some((i, _)) => format!("{title} (aka {})", &aka[..i]),
            None => format!("{title} (aka {aka})"),
        };
        Note {
            folder,
            title,
            title_text: cut(&clean_heading(title), MAX_PREFIX).to_string(),
            head,
        }
    }
}

/// `prefix\nlead\n\nrest`: the prefix is one line (no heading, title or
/// alias holds a line break).
fn with_lead(input: &str, lead: &str) -> String {
    match input.split_once("\n\n") {
        Some((prefix, rest)) => format!("{prefix}\n{lead}\n\n{rest}"),
        None => format!("{input}\n{lead}"),
    }
}

/// Keys whose values never reach a dense input: in the prefix already, or
/// filters, trust and lifecycle fields (spec C7).
const NOT_MEANING: [&str; 15] = [
    "title",
    "aliases",
    "alias",
    "description",
    "type",
    "tags",
    "tag",
    "resource",
    "generated",
    "verified",
    "status",
    "stale_after",
    "sources",
    "cssclasses",
    "publish",
];

/// The string and string-list values of a frontmatter block, one per line,
/// each at most 200 chars, at most 1 KB in all; dates are skipped.
/// ponytail: only the block shapes `yaml::parse` reads (most); any other
/// block gives none, and the point is dense on its head alone.
fn props(block: &str) -> String {
    use serde_json::Value;
    let mut out = String::new();
    let date = re!(r"^\d{4}-\d{2}-\d{2}");
    for (k, v) in crate::yaml::parse(block).unwrap_or_default() {
        if NOT_MEANING.contains(&k.as_str()) {
            continue;
        }
        let vals = match serde_json::from_str(&v).unwrap_or_default() {
            Value::String(s) => vec![s],
            Value::Array(a) => a
                .into_iter()
                .filter_map(|x| x.as_str().map(str::to_string))
                .collect(),
            _ => vec![],
        };
        for v in &vals {
            let v = v.trim();
            if v.is_empty() || date.is_match(v) {
                continue;
            }
            let v = v.char_indices().nth(200).map_or(v, |(i, _)| &v[..i]);
            if out.len() + 1 + v.len() > 1024 {
                return out;
            }
            if !out.is_empty() {
                out.push('\n');
            }
            out.push_str(v);
        }
    }
    out
}

/// The body's section chunks; true if any was emitted.
fn chunk_body(body: &str, note: &Note, coalesce: bool, emit: &mut impl FnMut(Chunk)) -> bool {
    let mut sections = Sections {
        body,
        note,
        emit,
        stack: Vec::new(),
        start: 0,
        head_end: 0,
        emitted: false,
        title_seen: false,
        coalesce,
        pending: None,
    };
    if may_have_heading(body) {
        segmented(body, SEGMENT, segment_headings_guarded, |hs| {
            hs.into_iter().for_each(|h| sections.heading(h))
        });
    }
    sections.close(body.len());
    sections.flush();
    sections.emitted
}

/// The section being read and the headings above it.
struct Sections<'a, 'e, F: FnMut(Chunk)> {
    body: &'a str,
    note: &'a Note<'a>,
    emit: &'e mut F,
    /// (level, text, is the title H1)
    stack: Vec<(usize, String, bool)>,
    start: usize,
    head_end: usize,
    emitted: bool,
    title_seen: bool,
    /// Over budget: sections that fit in one chunk are joined into one
    /// until it would pass MAX_CHUNK, whatever their size or kind.
    coalesce: bool,
    pending: Option<Pending>,
}

/// Sections joined into one chunk so far.
struct Pending {
    text: String,
    /// The path every member shares: the chunk's prefix and heading path,
    /// so a hit in a later member is not labelled with the first one's
    /// section (review M1).
    path: Vec<String>,
    /// The first member's, and whether its breadcrumb is in `text` yet.
    first: Vec<String>,
    first_crumb: bool,
    /// The last member's, for the next breadcrumb.
    last: Vec<String>,
    /// Bytes of member text, and of breadcrumb lines (newlines included).
    /// Breadcrumbs never outgrow the text they label, so a merged chunk is
    /// at most twice its members: a deep tree of tiny sections repeated a
    /// full path per member, 11x the note (#2150 review).
    body: usize,
    crumbs: usize,
    kind: &'static str,
    members: u16,
    /// The last member is a content-defined boundary: the chunk ends there.
    closed: bool,
    from: usize,
    to: usize,
}

/// One section in this many ends a min512 chunk, chosen by its own text
/// (`boundary`), so an edit or an inserted section re-groups only the
/// chunk it lands in and its neighbour, not every chunk after it (review
/// H2; the cap groups use the same rule). 4 keeps groups of ~4 small
/// sections: most of the point saving of greedy packing.
const MERGE_EVERY: u64 = 4;

/// The unkeyed SHA-256 of a section's text, first 48 bits, as the cap
/// groups in `Indexing` take it: a DEK rotation never moves a boundary.
fn boundary(text: &str) -> bool {
    use sha2::{Digest, Sha256};
    let d = Sha256::digest(text.as_bytes());
    let h = d[..6].iter().fold(0u64, |h, &b| h << 8 | u64::from(b));
    h % MERGE_EVERY == 0
}

/// The longest common prefix of two paths.
fn common(a: &[String], b: &[String]) -> Vec<String> {
    a.iter()
        .zip(b)
        .take_while(|(x, y)| x == y)
        .map(|(x, _)| x.clone())
        .collect()
}

impl<F: FnMut(Chunk)> Sections<'_, '_, F> {
    fn heading(&mut self, h: Heading) {
        self.close(h.start);
        // The H1 that IS the title is not repeated in the path. Matched by
        // text: a frontmatter title or an earlier setext H1 leaves it shown.
        let is_title = !self.title_seen && h.level == 1 && h.text == self.note.title_text;
        self.title_seen |= is_title;
        self.stack.retain(|&(l, _, _)| l < h.level);
        self.stack.push((h.level, h.text, is_title));
        self.start = h.start;
        self.head_end = h.end;
    }

    /// Emits the section from `start` (its heading included) to `end`,
    /// unless nothing but the heading is there.
    fn close(&mut self, end: usize) {
        let head_end = self.head_end.clamp(self.start, end);
        let rest = strip_blobs(&self.body[head_end..end]);
        if markup_only(&rest) {
            return;
        }
        let text = normalize(&self.body[self.start..head_end], &rest);
        let path = heading_path(self.note.title, &self.stack);
        if text.len() <= MAX_CHUNK {
            self.pend(text, path, end);
            return;
        }
        self.flush();
        for (t, kind) in classified(split(&text)) {
            (self.emit)(make(self.note, &path, t, self.start, end, kind));
            self.emitted = true;
        }
    }

    /// Bytes `p` grows by if `path`'s section joins it: the separator, the
    /// section, its breadcrumb, and the first member's breadcrumb once the
    /// shared path no longer holds the first member's parents. A breadcrumb
    /// is left out when it would take the chunk's breadcrumbs past its
    /// members' text; the prefix still shows the path they share.
    fn joined(p: &Pending, path: &[String], text: &str) -> (usize, Option<String>, Option<String>) {
        let shared = common(&p.path, path);
        let room = p.body + text.len();
        let mut used = p.crumbs;
        let mut fit = |c: Option<String>| {
            c.filter(|c| used + c.len() < room)
                .inspect(|c| used += c.len() + 1)
        };
        let first = fit((!p.first_crumb && p.first.len() > shared.len() + 1)
            .then(|| breadcrumb(&p.first))
            .flatten());
        let crumb = fit((p.last != path).then(|| breadcrumb(path)).flatten());
        (2 + text.len() + used - p.crumbs, first, crumb)
    }

    /// Joins a section that fits in one chunk to the ones before it while
    /// either side is under MIN_CHUNK, the kinds match, the sum fits and
    /// the last member is not a content-defined `boundary` (over budget:
    /// whenever it fits). A member under other headings than the one before
    /// it starts with a breadcrumb line, `A > B` (the path without the
    /// title), while the chunk's breadcrumbs fit in its members' text
    /// (`joined`); the prefix shows only the path all members share.
    fn pend(&mut self, text: String, path: Vec<String>, end: usize) {
        let kind = classify(&text, Fence::Out).0;
        let closes = boundary(&text);
        if let Some(p) = &mut self.pending {
            let (add, first, crumb) = Self::joined(p, &path, &text);
            let fits = p.text.len() + add <= MAX_CHUNK;
            let small = p.text.len() < MIN_CHUNK || text.len() < MIN_CHUNK;
            let open = !p.closed && small && p.kind == kind;
            if fits && (self.coalesce || open) {
                p.crumbs += add - 2 - text.len();
                p.body += text.len();
                if let Some(c) = first {
                    p.text.insert_str(0, &format!("{c}\n"));
                    p.first_crumb = true;
                }
                p.text.push_str("\n\n");
                if let Some(c) = crumb {
                    p.text.push_str(&c);
                    p.text.push('\n');
                }
                p.text.push_str(&text);
                p.path = common(&p.path, &path);
                p.to = end;
                p.last = path;
                p.members += 1;
                p.closed = closes;
                return;
            }
            self.flush();
        }
        self.pending = Some(Pending {
            body: text.len(),
            crumbs: 0,
            text,
            first: path.clone(),
            first_crumb: false,
            last: path.clone(),
            path,
            kind,
            members: 1,
            closed: closes,
            from: self.start,
            to: end,
        });
    }

    fn flush(&mut self) {
        if let Some(p) = self.pending.take() {
            // Members share a kind unless over budget; the whole decides.
            let kind = classify(&p.text, Fence::Out).0;
            let mut c = make(self.note, &p.path, &p.text, p.from, p.to, kind);
            c.3 .1 = p.members;
            (self.emit)(c);
            self.emitted = true;
        }
    }
}

const PROSE: &str = "prose";
const FRONTMATTER_DENSE: &str = "frontmatter_dense";

/// An Excalidraw note (a frontmatter line starting `excalidraw-plugin:`) is
/// indexed by its text elements: the ```json / ```compressed-json drawing
/// fences after `## Drawing` (`# Drawing` in the old format) leave the indexed text, and so do the ` ^id` block refs that
/// end the element lines. The note keeps every byte. Chunk offsets count the
/// edited body.
fn excalidraw<'a>(block: Option<&str>, body: &'a str) -> std::borrow::Cow<'a, str> {
    if !block.is_some_and(|b| b.lines().any(|l| l.starts_with("excalidraw-plugin:"))) {
        return body.into();
    }
    let (head, tail) = match re!(r"(?m)^##? Drawing[ \t]*$").find(body) {
        Some(m) => body.split_at(m.start()),
        None => (body, ""),
    };
    let head = re!(r"(?m)[ \t]+\^[A-Za-z0-9]{6,}[ \t]*$").replace_all(head, "");
    let tail = re!(r"(?ms)^```(?:compressed-)?json[^\n]*\n.*?^```[ \t]*$").replace_all(tail, "");
    format!("{head}{tail}").into()
}

/// Where a line sits: outside a code fence, in one, or in a query block
/// (Dataview, Tasks, Obsidian query/base), which is not meaning either.
#[derive(Clone, Copy, PartialEq)]
enum Fence {
    Out,
    Code,
    Query,
}

/// `data` for a body chunk that is mostly not words (minified JSON, CSV of
/// numbers, log dumps, number tables): it is keyword-only, as a dense vector
/// of it means nothing. Judged per paragraph (blank-line runs), so a table
/// does not take the dense leg off the analysis above it: the chunk is
/// `data` only when 80% or more of its bytes sit in data-shaped paragraphs.
/// Inside a code fence a line is judged as code (`junk_line`): code is
/// searched by meaning, minified JS and logs are not. A chunk is `data`
/// when over 65% of it is query blocks (at any size), or, from 200 bytes,
/// junk lines and query blocks. Linear time. `fence`: where the chunk
/// starts. Returns where it ends.
fn classify(text: &str, mut fence: Fence) -> (&'static str, Fence) {
    let (mut data, mut junk, mut query) = (0, 0, 0);
    let mut para: Option<(usize, usize)> = None;
    let mut pos = 0;
    for line in text.split_inclusive('\n') {
        let end = pos + line.len();
        let t = line.trim_start();
        let is_fence = t.starts_with("```") || t.starts_with("~~~");
        if fence != Fence::Out || is_fence || t.is_empty() {
            data += para.take().map_or(0, |(s, e)| data_bytes(&text[s..e]));
        } else {
            para = Some((para.map_or(pos, |(s, _)| s), end));
        }
        let before = fence;
        if is_fence {
            fence = match fence {
                Fence::Out if query_info(&t[3..]) => Fence::Query,
                Fence::Out => Fence::Code,
                _ => Fence::Out,
            };
        }
        match (before, fence) {
            (Fence::Query, _) | (_, Fence::Query) => query += line.len(),
            (Fence::Code, Fence::Code) if junk_line(line) => junk += line.len(),
            _ => {}
        }
        pos = end;
    }
    data += para.map_or(0, |(s, e)| data_bytes(&text[s..e]));
    let n = text.len();
    let mostly = |b: usize| b * 100 > n * 65;
    if mostly(query) || (n >= 200 && (data * 100 >= n * 80 || mostly(junk + query))) {
        ("data", fence)
    } else {
        (PROSE, fence)
    }
}

/// A fence info string naming a query block.
fn query_info(info: &str) -> bool {
    let word = info
        .trim_start_matches(['`', '~'])
        .split_whitespace()
        .next();
    matches!(
        word,
        Some("dataview" | "dataviewjs" | "tasks" | "query" | "base")
    )
}

/// A code line that is not code to read: minified (over 400 bytes, under
/// 5% whitespace), a log line (it opens with a date or a time), or a dump
/// (digits are half of its non-space bytes, from 24 of them). A quarter
/// caught CSS, constant tables and configs, which are code (review L2).
fn junk_line(line: &str) -> bool {
    let t = line.trim();
    let ws = t.bytes().filter(u8::is_ascii_whitespace).count();
    let solid = t.len() - ws;
    let digits = t.bytes().filter(u8::is_ascii_digit).count();
    let stamped = re!(r"^\[?(\d{4}-\d{2}-\d{2}|\d{2}:\d{2}:\d{2})").is_match(t);
    (t.len() > 400 && ws * 20 < t.len()) || stamped || (solid >= 24 && digits * 2 >= solid)
}

/// `p.len()` when the paragraph is data-shaped, else 0. Data-shaped: under
/// 35% of its tokens are words, unless it is written in a script without
/// spaces (CJK: non-ASCII letters are most of the text). Tokens with no
/// letter or digit (`|`, `---`, `-`) are markup and not counted, so a
/// table of words is prose.
fn data_bytes(p: &str) -> usize {
    let (mut wide, mut other) = (0, 0);
    let (mut words, mut tokens) = (0, 0);
    for tok in p.split_whitespace() {
        for c in tok.chars() {
            if c.is_alphabetic() && !c.is_ascii() {
                wide += 1;
            } else {
                other += 1;
            }
        }
        // `[[Note|Alias]]`: both sides are words.
        let parts = if tok.contains("[[") {
            tok.split('|')
        } else {
            tok.split('\u{0}')
        };
        for tok in parts.filter(|t| t.chars().any(char::is_alphanumeric)) {
            tokens += 1;
            words += (word(tok) || wide_word(tok)) as usize;
        }
    }
    // Non-ASCII letters only: string-heavy minified JSON is over half ASCII
    // letters, and the word rule is what catches it.
    let prose = tokens == 0 || wide >= other || words * 100 >= tokens * 35;
    if prose {
        0
    } else {
        p.len()
    }
}

/// The pieces of one section with their kinds. A code block longer than a
/// chunk leaves pieces with no fence of their own, so the fence state
/// carries from piece to piece.
fn classified(pieces: Vec<&str>) -> impl Iterator<Item = (&str, &'static str)> {
    let mut fence = Fence::Out;
    pieces.into_iter().map(move |t| {
        let (kind, after) = classify(t, fence);
        fence = after;
        (t, kind)
    })
}

/// 2+ letters, letters only (an inner `'` or `-` allowed), with markup and
/// punctuation trimmed from both ends: `[[Inbox]]`, `**Owner:**` and `"so"`
/// are words. `[Why Rust](https://...)`: the title counts, the url does not.
fn word(tok: &str) -> bool {
    let tok = tok.split("](").next().unwrap_or(tok);
    let w = tok
        .trim_start_matches(['[', '(', '*', '_', '`', '"', '\'', '#', '>', '~'])
        .trim_end_matches(|c: char| !c.is_alphanumeric());
    w.chars().filter(|c| c.is_alphabetic()).count() >= 2
        && w.chars()
            .all(|c| c.is_alphabetic() || matches!(c, '\'' | '’' | '-'))
        && w.starts_with(char::is_alphabetic)
}

/// A token of a script written without spaces (CJK): a whole clause, inline
/// code included, is one token. 2+ non-ASCII letters, at least as many as
/// its ASCII letters and digits, so minified JSON with a few non-ASCII
/// string values stays a non-word.
fn wide_word(tok: &str) -> bool {
    let wide = tok
        .chars()
        .filter(|c| c.is_alphabetic() && !c.is_ascii())
        .count();
    wide >= 2 && wide >= tok.chars().filter(char::is_ascii_alphanumeric).count()
}

/// `path` is the heading path, title first; the prefix shows the note's
/// head (title and aliases) in the title's place.
fn make(note: &Note, path: &[String], text: &str, s: usize, e: usize, kind: &'static str) -> Chunk {
    let folder = note.folder;
    let emb = prefix(&note.head, &path[1..]);
    let ctx = if folder.is_empty() {
        emb.clone()
    } else {
        // The folder gives way first: the heading is what the chunk is about.
        let room = MAX_PREFIX.saturating_sub(emb.len() + 3);
        match cut(folder, room) {
            "" => emb.clone(),
            f => format!("{f} > {emb}"),
        }
    };
    (
        text.to_string(),
        format!("{ctx}\n\n{text}"),
        format!("{emb}\n\n{text}"),
        (path.to_vec(), 1),
        s,
        e,
        kind,
    )
}

/// `head > h1 > h2 > leaf` in at most MAX_PREFIX bytes (Voyage rejects an
/// oversized input with a permanent 400; texts are bounded by `split`). It
/// always ends with the leaf heading: ancestors go first, top down, then
/// the head and the leaf share the room, the leaf keeping at least half.
fn prefix(head: &str, hs: &[String]) -> String {
    let Some((leaf, mut up)) = hs.split_last() else {
        return cut(head, MAX_PREFIX).to_string();
    };
    let len =
        |up: &[String]| head.len() + up.iter().map(|h| h.len() + 3).sum::<usize>() + 3 + leaf.len();
    while !up.is_empty() && len(up) > MAX_PREFIX {
        up = &up[1..];
    }
    if len(up) > MAX_PREFIX {
        let leaf = cut(
            leaf,
            (MAX_PREFIX - 3)
                .saturating_sub(head.len())
                .max(MAX_PREFIX / 2),
        );
        let head = cut(head, MAX_PREFIX - 3 - leaf.len());
        return format!("{head} > {leaf}");
    }
    let mut out = head.to_string();
    for h in up.iter().chain([leaf]) {
        out.push_str(" > ");
        out.push_str(h);
    }
    out
}

/// A merged member's breadcrumb: its path without the title, when that is
/// more than its own heading (which already opens its text).
fn breadcrumb(path: &[String]) -> Option<String> {
    (path.len() > 2).then(|| prefix(&path[1], &path[2..]))
}

/// The first `max` bytes of `s`, cut at a char boundary.
fn cut(s: &str, max: usize) -> &str {
    &s[..floor_boundary(s, max.min(s.len()))]
}

/// ATX needs a `#`, setext an underline line of `=` or `-`. Without either
/// pulldown-cmark finds no heading, and a blob-only note skips the parse.
fn may_have_heading(s: &str) -> bool {
    s.contains('#')
        // pulldown-cmark also ends a line at a lone \r.
        || s.split(['\n', '\r'])
            .any(|l| matches!(l.trim_start().as_bytes().first(), Some(b'=' | b'-')))
}

fn segment_headings_guarded(s: &str, at: usize, out: &mut Vec<Heading>) -> Option<usize> {
    // pulldown-cmark 0.13.4 panics on some valid input (see links).
    // ponytail: a panicking segment loses its headings, not the note; its
    // text still chunks under the previous heading.
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        segment_headings(s, at, out)
    }))
    .unwrap_or(None)
}

/// Top-level headings with text, offset by `at`. Returns the start of a
/// fenced or raw-HTML block running to the end of `s`, if any.
fn segment_headings(s: &str, at: usize, out: &mut Vec<Heading>) -> Option<usize> {
    let mut depth = 0usize;
    let mut open = None;
    for (event, r) in Parser::new_ext(s, Options::ENABLE_TABLES).into_offset_iter() {
        match event {
            Event::Start(Tag::BlockQuote(_) | Tag::List(_) | Tag::Item) => depth += 1,
            Event::End(TagEnd::BlockQuote(_) | TagEnd::List(_) | TagEnd::Item) => depth -= 1,
            Event::Start(Tag::Heading { level, .. }) if depth == 0 => {
                // An empty heading (`#`) never split a section, as in v2.
                let src = &s[r.clone()];
                let text = heading_text(src);
                if !text.is_empty() {
                    // After a link reference definition, pulldown-cmark can
                    // start a setext heading on the blank line before it.
                    let lead = src.len() - src.trim_start().len();
                    out.push(Heading {
                        level: level as usize,
                        start: at + r.start + lead,
                        end: at + r.end,
                        text,
                    });
                }
            }
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

/// The heading's source text, at most MAX_PREFIX bytes: ATX without its `#`
/// runs, setext without its underline (lines joined by a space). A setext
/// heading can be a whole paragraph, and its text lands in every path below
/// it, so only the first bytes are read.
fn heading_text(src: &str) -> String {
    let whole = src.len();
    let src = &src[..floor_boundary(src, src.len().min(4 * MAX_PREFIX))];
    // Cut short, a setext heading has lost its underline: every line is text.
    let underlined = src.len() == whole;
    let src = src.trim_end();
    let first = src.trim_start();
    let hashes = first.bytes().take_while(|&c| c == b'#').count();
    let text = if (1..=6).contains(&hashes) && !src.contains('\n') {
        let t = first[hashes..].trim();
        // A closing sequence counts only after a space, or as the whole text.
        let closing = t.trim_end_matches('#');
        if closing.is_empty() || closing.ends_with([' ', '\t']) {
            closing.trim_end().to_string()
        } else {
            t.to_string()
        }
    } else {
        let lines: Vec<&str> = src.lines().collect();
        let body = &lines[..lines.len().saturating_sub(underlined as usize)];
        body.iter()
            .map(|l| l.trim())
            .filter(|l| !l.is_empty())
            .collect::<Vec<_>>()
            .join(" ")
    };
    cut(&clean_heading(&text), MAX_PREFIX).to_string()
}

/// A heading as it reads: `[[a|b]]` is `b`, `[[a]]` is `a`, `[t](u)` is
/// `t` (no url in the prefix), emphasis, code and strike marks and bidi
/// controls dropped, spaces collapsed.
fn clean_heading(h: &str) -> String {
    let h = re!(r"\[\[[^\]|]*\|([^\]]*)\]\]").replace_all(h, "$1");
    let h = re!(r"\[\[([^\]]*)\]\]").replace_all(&h, "$1");
    let h = re!(r"!?\[([^\]]*)\]\([^)]*\)").replace_all(&h, "$1");
    let h = re!(r"[*_`~\u{200E}\u{200F}\u{061C}\u{202A}-\u{202E}\u{2066}-\u{2069}]")
        .replace_all(&h, "");
    h.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn heading_path(title: &str, stack: &[(usize, String, bool)]) -> Vec<String> {
    std::iter::once(title.to_string())
        .chain(stack.iter().filter(|h| !h.2).map(|h| h.1.clone()))
        .collect()
}

/// No letter, digit or symbol (emoji count): blank, a heading alone, or a
/// blob and its markup.
fn markup_only(text: &str) -> bool {
    !re!(r"[\p{L}\p{N}\p{So}]").is_match(text)
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

/// Base64 and hex blobs are removed from the indexed text; the note keeps
/// every byte. A run must also LOOK encoded, so a long URL or path in the
/// same character class survives.
fn strip_blobs(text: &str) -> std::borrow::Cow<'_, str> {
    let text = strip_wrapped(text);
    let out = re!(r"(?:data:[A-Za-z0-9_/+.-]+;base64,)?([A-Za-z0-9+/=_-]{100,})").replace_all(
        &text,
        |c: &regex::Captures| {
            let body = &c[1];
            let blob = encoded(body) || random_hex(body);
            if blob {
                String::new()
            } else {
                c[0].to_string()
            }
        },
    );
    match out {
        std::borrow::Cow::Borrowed(_) => text,
        std::borrow::Cow::Owned(s) => s.into(),
    }
}

/// 60-120 base64 chars: PEM wraps at 64, MIME and `base64 -w` at 76. Under
/// 60 sit identifiers that must stay searchable (ETH addresses 42, Solana
/// 32-44, IPFS CIDv0 46).
fn b64_line(line: &str) -> bool {
    (60..=120).contains(&line.trim().len()) && b64_chars(line)
}

fn b64_chars(line: &str) -> bool {
    let l = line.trim();
    !l.is_empty()
        && l.bytes()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'+' | b'/' | b'='))
}

fn pem_armour(line: &str, word: &str) -> bool {
    let l = line.trim();
    l.starts_with("-----") && l.ends_with("-----") && l[5..].starts_with(word)
}

/// Runs of 3+ lines of 60-120 base64 chars (PEM bodies, MIME parts) that
/// together look encoded, plus the PEM armour lines around them. After a
/// BEGIN line the run also takes the short last line, so the END line is
/// next and goes too. One linear line scan, no regex.
fn strip_wrapped(text: &str) -> std::borrow::Cow<'_, str> {
    // Byte ranges to drop; a note with no wrapped blob allocates nothing.
    let mut cut: Vec<(usize, usize)> = Vec::new();
    let mut prev: Option<(usize, &str)> = None;
    let mut run: Option<(usize, usize, usize)> = None; // start, end, lines
    let mut sample = String::new(); // first 4 KB of the run, what encoded() reads
    let mut pem = false; // the run follows a BEGIN armour line
    let mut pos = 0;
    let mut close = |run: &mut Option<(usize, usize, usize)>,
                     sample: &mut String,
                     prev: Option<(usize, &str)>,
                     next: Option<(usize, usize, &str)>| {
        if let Some((s, e, n)) = run.take() {
            if n >= 3 && encoded(sample) {
                let s = match prev {
                    Some((ps, l)) if pem_armour(l, "BEGIN") => ps,
                    _ => s,
                };
                let e = match next {
                    Some((_, ne, l)) if pem_armour(l, "END") => ne,
                    _ => e,
                };
                cut.push((s, e));
            }
        }
        sample.clear();
    };
    for line in text.split_inclusive('\n') {
        let end = pos + line.len();
        if b64_line(line) || (pem && run.is_some() && b64_chars(line)) {
            match &mut run {
                Some((_, e, n)) => {
                    *e = end;
                    *n += 1;
                }
                None => {
                    run = Some((pos, end, 1));
                    pem = prev.is_some_and(|(_, l)| pem_armour(l, "BEGIN"));
                }
            }
            if sample.len() < 4096 {
                sample.push_str(line.trim());
            }
        } else {
            close(&mut run, &mut sample, prev, Some((pos, end, line)));
            pem = false;
            prev = Some((pos, line));
        }
        pos = end;
    }
    close(&mut run, &mut sample, prev, None);
    if cut.is_empty() {
        return text.into();
    }
    let mut out = String::with_capacity(text.len());
    let mut from = 0;
    for (s, e) in cut {
        // An END armour line already swallowed by the previous cut cannot
        // overlap: it is not a base64 line, so no later run starts inside it.
        out.push_str(&text[from..s]);
        from = e;
    }
    out.push_str(&text[from..]);
    out.into()
}

/// A hex dump: 256+ hex chars that also look random (digits AND letters),
/// so sha256/sha512 hashes stay searchable and "aaaa..." is plain text.
fn random_hex(run: &str) -> bool {
    if run.len() < 256 || !run.bytes().all(|b| b.is_ascii_hexdigit()) {
        return false;
    }
    let sample = &run.as_bytes()[..run.len().min(4096)];
    let d = sample.iter().filter(|b| b.is_ascii_digit()).count();
    let len = sample.len() as f64;
    d as f64 >= len * 0.2 && (sample.len() - d) as f64 >= len * 0.2
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
/// `units`), cut at local hash maxima (see WINDOW). Chunks with no letter or
/// digit are dropped.
fn split(text: &str) -> Vec<&str> {
    if text.len() <= MAX_CHUNK {
        return vec![text];
    }
    let mut pack = Packer {
        text,
        out: Vec::new(),
        from: 0,
        to: 0,
    };
    let mut cuts = LocalMax::new(text.len());
    units(text, 0, 0, &mut |s, e| {
        cuts.push(s, e, hash(&text[s..e]), &mut |s, e, cut| {
            pack.unit(s, e, cut)
        });
    });
    cuts.finish(&mut |s, e, cut| pack.unit(s, e, cut));
    if pack.to > pack.from {
        pack.out.push(&text[pack.from..pack.to]);
    }
    let mut out = pack.out;
    out.retain(|t| !markup_only(t));
    out.iter_mut().for_each(|t| *t = t.trim());
    out
}

/// Greedy packing between cuts.
struct Packer<'a> {
    text: &'a str,
    out: Vec<&'a str>,
    from: usize,
    to: usize,
}

impl Packer<'_> {
    fn unit(&mut self, s: usize, e: usize, cut: bool) {
        let text = self.text;
        if e - self.from > MAX_CHUNK && self.to > self.from {
            let at = if cut {
                // The gap ends here and holds at most 2 * MAX_CHUNK: halve
                // it at a word break, so neither piece is a runt.
                let mid = floor_boundary(text, (self.from + e) / 2);
                let lo = floor_boundary(text, e - MAX_CHUNK);
                word_break(text, lo, mid).unwrap_or(mid)
            } else if self.to - self.from >= RUNT {
                self.to
            } else {
                // A runt (a heading before a long run) rides with the unit,
                // cut at its last word break that fits.
                let at = floor_boundary(text, self.from + MAX_CHUNK);
                word_break(text, s, at).unwrap_or(at)
            };
            self.out.push(&text[self.from..at]);
            self.from = at;
        }
        self.to = e;
        if cut {
            self.out.push(&text[self.from..self.to]);
            self.from = e;
        }
    }
}

struct Unit {
    s: usize,
    e: usize,
    h: u64,
    left: bool,
    right: bool,
}

/// Streams units in order and decides, WINDOW bytes later, whether each is
/// a cut: a strict maximum of the hash among units ending within WINDOW
/// either side, and at least WINDOW from both ends of the text (no runt at
/// either end). Holds only the units of the last WINDOW bytes.
struct LocalMax {
    len: usize,
    lag: std::collections::VecDeque<Unit>,
    /// Ids of `lag`, hash strictly decreasing: the sliding-window maximum.
    mono: std::collections::VecDeque<usize>,
    base: usize,
}

impl LocalMax {
    fn new(len: usize) -> Self {
        Self {
            len,
            lag: Default::default(),
            mono: Default::default(),
            base: 0,
        }
    }

    fn push(&mut self, s: usize, e: usize, h: u64, emit: &mut impl FnMut(usize, usize, bool)) {
        while self.lag.front().is_some_and(|u| u.e + WINDOW <= e) {
            self.pop(emit);
        }
        let left = self
            .mono
            .front()
            .is_none_or(|&m| self.lag[m - self.base].h < h);
        while let Some(&m) = self.mono.back() {
            let u = &mut self.lag[m - self.base];
            if u.h > h {
                break;
            }
            u.right = false;
            self.mono.pop_back();
        }
        self.mono.push_back(self.base + self.lag.len());
        self.lag.push_back(Unit {
            s,
            e,
            h,
            left,
            right: true,
        });
    }

    fn pop(&mut self, emit: &mut impl FnMut(usize, usize, bool)) {
        let u = self.lag.pop_front().expect("pop on a non-empty lag");
        if self.mono.front() == Some(&self.base) {
            self.mono.pop_front();
        }
        self.base += 1;
        let cut = u.left && u.right && u.e >= WINDOW && u.e + WINDOW <= self.len;
        emit(u.s, u.e, cut);
    }

    fn finish(mut self, emit: &mut impl FnMut(usize, usize, bool)) {
        while !self.lag.is_empty() {
            self.pop(emit);
        }
    }
}

/// FNV-1a of a unit's trimmed text.
fn hash(unit: &str) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in unit.trim().as_bytes() {
        h = (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3);
    }
    h
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
            for piece in word_split(text, MAX_CHUNK) {
                unit(at, at + piece.len());
                at += piece.len();
            }
        }
    }
}

fn floor_boundary(text: &str, mut i: usize) -> usize {
    while !text.is_char_boundary(i) {
        i -= 1;
    }
    i
}

/// The last cut in `text[lo..hi]` that leaves every word whole: after a
/// space or newline, else after any other char that is not alphanumeric
/// (`a,b`, `a;b`, `a|b`). None when the range is all one word.
fn word_break(text: &str, lo: usize, hi: usize) -> Option<usize> {
    let s = &text[lo..hi];
    s.rfind([' ', '\n'])
        .or_else(|| s.rfind(|c: char| !c.is_alphanumeric()))
        .map(|i| lo + i + s[i..].chars().next().map_or(1, char::len_utf8))
}

/// `hard_split`, but each cut moves back to a `word_break` in the piece's
/// second half, so a run without spaces (CSV, minified text, a YAML list on
/// one line) keeps its words whole: a word cut in two is two other tokens,
/// and keyword search can no longer find it. One word longer than half of
/// `max` is still cut at a char boundary.
fn word_split(text: &str, max: usize) -> Vec<&str> {
    let mut out = Vec::new();
    let mut rest = text;
    while rest.len() > max {
        let hi = floor_boundary(rest, max);
        let lo = floor_boundary(rest, max / 2);
        let cut = word_break(rest, lo, hi).unwrap_or(hi);
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
    let mut spans = Vec::new();
    segmented(body, segment, segment_headings_guarded, |hs| {
        spans.extend(hs.into_iter().map(|h| (h.level, h.start, h.end, h.text)))
    });
    (spans, may_have_heading(body))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn paths(content: &str) -> Vec<String> {
        chunk(content, "", "T")
            .into_iter()
            .map(|c| c.3 .0.join(" > "))
            .collect()
    }

    // 10 MB of `# h\nx\n` was 1.7M chunks: 466 MB of terms and ~13k Voyage
    // calls. Over budget, tiny sections coalesce into ~MAX_CHUNK chunks, so
    // every byte is still indexed but the count follows the size.
    #[test]
    fn tiny_sections_coalesce_past_the_budget() {
        let note = "# h\nx\n".repeat(200_000);
        let cs = chunk(&note, "", "T");
        let budget = super::budget(note.len());
        assert!(cs.len() <= budget, "{} chunks, budget {budget}", cs.len());
        assert!(cs.iter().all(|c| c.0.len() <= MAX_CHUNK));
        // Nothing dropped: every section's text is in some chunk.
        let xs: usize = cs.iter().map(|c| c.0.matches('x').count()).sum();
        assert_eq!(xs, 200_000);
        // Ranges stay in order and inside the body.
        assert!(cs
            .windows(2)
            .all(|w| w[0].4 <= w[1].4 && w[1].5 <= note.len()));
    }

    #[test]
    fn frontmatter_chunks_are_their_own_kind() {
        let cs = chunk("---\ntags: [a]\n---\n# T\n\nbody\n\n## S\n\nmore", "", "T");
        let kinds: Vec<_> = cs
            .iter()
            .map(|c| format!("{}: {}", c.3 .0.join(" > "), c.6))
            .collect();
        // The two small sections are one chunk (min512).
        assert_eq!(kinds, ["T: prose", "frontmatter: frontmatter"]);
    }

    #[test]
    fn notes_under_the_budget_join_small_sections() {
        // 300 sections of 16 bytes: joined into chunks of ~MAX_CHUNK.
        let note = "## s\n\nbody text\n\n".repeat(300);
        let cs = chunk(&note, "", "T");
        assert_eq!(
            cs.len(),
            300 * "## s\n\nbody text\n\n".len() / MAX_CHUNK + 1
        );
        assert_eq!(
            cs.iter()
                .map(|c| c.0.matches("body").count())
                .sum::<usize>(),
            300
        );
    }

    // A cut inside a word leaves two other tokens; keyword search loses it.
    #[test]
    fn a_run_with_no_space_keeps_its_words_whole() {
        let words: Vec<String> = (0..3_000).map(|i| format!("word{i}")).collect();
        let line = words.join(",");
        for content in [line.clone(), format!("---\nlist: {line}\n---\nbody")] {
            let found: std::collections::HashSet<String> = chunk(&content, "", "T")
                .iter()
                .flat_map(|c| {
                    c.0.split(|ch: char| !ch.is_alphanumeric())
                        .map(str::to_string)
                        .collect::<Vec<_>>()
                })
                .collect();
            assert!(words.iter().all(|w| found.contains(w)));
            assert!(chunk(&content, "", "T")
                .iter()
                .all(|c| c.0.len() <= MAX_CHUNK));
        }
    }

    #[test]
    fn code_is_not_a_heading() {
        let m = sized(600);
        assert_eq!(
            paths(&format!("# T\n\n```\n# x\n```\n{m}\n\n## N\n\n{m}")),
            ["T", "T > N"]
        );
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
        let m = sized(600);
        assert_eq!(paths(&format!("{m}\n\nS\n  ---\n\n{m}")), ["T", "T > S"]);
    }

    #[test]
    fn a_long_heading_is_capped_in_every_path() {
        let content = format!(
            "# T\n\n## {}\n\nbody\n\n### S\n\nmore",
            "word ".repeat(200_000)
        );
        let chunks = chunk(&content, "", "T");
        assert!(
            chunks
                .iter()
                .all(|c| c.3 .0.iter().all(|h| h.len() <= MAX_PREFIX)),
            "uncapped path"
        );
        let total: usize = chunks
            .iter()
            .map(|c| c.0.len() + c.1.len() + c.2.len() + c.3 .0.concat().len())
            .sum();
        assert!(total < 8 * content.len(), "{total} bytes of chunks");
    }

    // Reviewer inputs that drove the native peak to 18-72x the note.
    #[test]
    fn pathological_notes_stay_under_10x() {
        let mib = 1 << 20;
        let fill = |unit: &str| unit.repeat(mib / unit.len());
        for content in [
            fill("#\n"),
            fill("# h\n"),
            fill("a line of text\n") + "#tag\n",
            fill("-\n"),
            fill("h\n=\n"),
            fill(r#"{"id":4821,"ok":true},"#),
        ] {
            let ((), peak) =
                crate::memory::measured(|| each_chunk(&content, "f", "T", &[], None, |_| {}));
            assert!(peak <= 10 * content.len(), "{peak} for {:?}", &content[..8]);
        }
    }

    // Tiny leaves under five long parents: each merged member repeated the
    // full breadcrumb, 11x the note in text alone (#2150 review).
    #[test]
    fn breadcrumbs_never_outgrow_the_members_they_label() {
        let parents = |g: usize| -> String {
            (1..=5)
                .map(|l| {
                    format!(
                        "{} Parent level {l} group {g} with a long title\n\n",
                        "#".repeat(l)
                    )
                })
                .collect()
        };
        for leaves in [3_000, 30_000] {
            let content: String = (0..leaves)
                .map(|i| {
                    let head = if i % 1000 == 0 {
                        parents(i / 1000)
                    } else {
                        String::new()
                    };
                    format!("{head}###### leaf {i}\nword{i}\n\n")
                })
                .collect();
            let cs = chunk(&content, "f", "T");
            let text: usize = cs.iter().map(|c| c.0.len()).sum();
            assert!(text <= 2 * content.len(), "{text} for {}", content.len());
            let words: usize = cs.iter().map(|c| c.0.matches("\nword").count()).sum();
            assert_eq!(words, leaves);
        }
    }

    #[test]
    fn only_the_h1_matching_the_title_is_hidden() {
        // Sections of 600 B, so min512 leaves one chunk each.
        let m = sized(600);
        assert_eq!(paths(&format!("# T\n\n{m}\n\n# B\n\n{m}")), ["T", "T > B"]);
        // A frontmatter title that differs from the H1 keeps the H1.
        let c = chunk(
            &format!("---\ntitle: T\n---\n# Bar\n\n{m}\n\n## Sub\n\n{m}"),
            "",
            "T",
        );
        let p: Vec<_> = c.iter().map(|c| c.3 .0.join(" > ")).collect();
        assert_eq!(p, ["T > Bar", "T > Bar > Sub", "frontmatter"]);
        // A setext H1 before the title H1 is not mistaken for it.
        assert_eq!(
            paths(&format!("Intro\n===\n\n{m}\n\n# T\n\n{m}")),
            ["T > Intro", "T"]
        );
    }

    #[test]
    fn emoji_only_notes_are_kept() {
        assert_eq!(paths("🎉🎉 🚀 ✨\n"), ["T"]);
    }

    #[test]
    fn an_empty_heading_does_not_split() {
        assert_eq!(paths("a\n\n#\n\nb"), ["T"]);
    }

    fn indexed(s: &str) -> String {
        strip_blobs(s).into_owned()
    }

    fn b64_lines(n: usize, w: usize) -> String {
        let alpha = b"AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/aBcDeFgHiJkLmNoPqRsTuVwXyZ";
        (0..n)
            .map(|r| {
                (0..w)
                    .map(|i| alpha[(i * 7 + r * 13) % 64] as char)
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn pem_block_is_stripped_prose_kept() {
        let note = format!(
            "before text\n-----BEGIN CERTIFICATE-----\n{}\n-----END CERTIFICATE-----\nafter text",
            b64_lines(5, 64)
        );
        assert_eq!(indexed(&note), "before text\nafter text");
    }

    #[test]
    fn mime_attachment_is_stripped() {
        let note = format!("hello\n\n{}\n\nbye", b64_lines(8, 76));
        assert_eq!(indexed(&note), "hello\n\n\nbye");
    }

    #[test]
    fn random_hex_dump_is_stripped_hashes_and_repeats_kept() {
        let dump = "0123456789abcdef".repeat(32);
        assert_eq!(indexed(&format!("sum {dump} end")), "sum  end");
        let sha512 = "0123456789abcdef".repeat(8);
        let keep = format!("sha {sha512} commit 2fc980c3a1b0d5e7f9a1b2c3d4e5f60718293a4b deadbeef");
        assert_eq!(indexed(&keep), keep);
        for same in ["a".repeat(300), "A".repeat(10_000), "7".repeat(300)] {
            assert_eq!(indexed(&same), same);
        }
    }

    #[test]
    fn urls_paths_and_tables_are_kept() {
        let url = format!("https://example.com/{}", "segment/".repeat(20));
        let path = format!("/home/user/{}", "dir42/".repeat(20));
        let table = "| a | b |\n|---|---|\n| one | two |\n| three | four |\n";
        for s in [url.as_str(), path.as_str(), table] {
            assert_eq!(indexed(s), s);
        }
        // Two wrapped lines are below the 3-line threshold.
        let two = b64_lines(2, 64);
        assert_eq!(indexed(&two), two);
    }

    #[test]
    fn wallet_addresses_and_cids_stay_in_the_index() {
        let notes = [
            "## Wallets\n7EcDhSYGxXyscszYEp35KHN8vvw3svAuLKTzXwCFLtV\n\
             9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin\n\
             4k3Dyjzvzp8eMZWUXbBCjEvwSkkk59S5iCNLY3QrkX6R\n",
            "## Wallets\n0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed\n\
             0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359\n\
             0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB\n",
            "## Pins\nQmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG\n\
             QmT78zSuBmuS4z925WZfrqQ1qHaJ56DQaTfyMUF7F8ff5o\n\
             QmPZ9gcCEpqKTo6aq61g2nXGUhM4iCL3ewB6LDXZCtioEB\n",
        ];
        for note in notes {
            assert_eq!(indexed(note), note);
        }
    }

    /// Self-signed certs (RSA 1024-4096, P-256, Ed25519): their last base64
    /// line runs from 4 to 64 chars.
    const CERTS: &str = include_str!("testdata/certs.pem");

    #[test]
    fn real_certificates_leave_no_base64_or_armour() {
        let certs: Vec<String> = CERTS
            .split_inclusive("-----END CERTIFICATE-----\n")
            .map(str::to_string)
            .collect();
        assert_eq!(certs.len(), 6);
        for cert in certs {
            let out = indexed(&format!("The staging cert:\n{cert}Rotate it yearly.\n"));
            assert_eq!(out, "The staging cert:\nRotate it yearly.\n");
        }
    }

    #[test]
    fn multibyte_text_next_to_a_pem_block_survives() {
        let note = format!(
            "Привет мир\n-----BEGIN CERTIFICATE-----\n{}\n-----END CERTIFICATE-----\nПока мир",
            b64_lines(5, 64)
        );
        assert_eq!(indexed(&note), "Привет мир\nПока мир");
    }

    #[test]
    fn empty_body_and_blank_note() {
        assert!(chunk("", "", "T").is_empty());
        assert!(chunk("   \n\n", "", "T").is_empty());
    }

    fn kinds(note: &str) -> Vec<&'static str> {
        chunk(note, "", "T").into_iter().map(|c| c.6).collect()
    }

    fn all(note: &str, kind: &str) {
        let ks = kinds(note);
        assert!(!ks.is_empty() && ks.iter().all(|k| *k == kind), "{ks:?}");
    }

    #[test]
    fn minified_json_is_data() {
        let rec = r#"{"id":4821,"name":"Alice Smith","role":"admin","tags":["work","home"],"score":12.5,"ok":true}"#;
        let json = format!("[{}]", vec![rec; 21].join(","));
        assert!(json.len() > 1900 && json.len() < MAX_CHUNK);
        all(&json, "data");
    }

    #[test]
    fn numeric_csv_is_data() {
        let rows: Vec<String> = (0..40)
            .map(|i| format!("{i},{}.25,{},2026-10-{:02}", i * 7, i * 31 % 97, i % 28 + 1))
            .collect();
        all(&format!("id,value,count,date\n{}", rows.join("\n")), "data");
    }

    #[test]
    fn log_dump_is_data() {
        let lines: Vec<String> = (0..30)
            .map(|i| format!("2026-10-19T05:14:{i:02}.0863647Z id=7f3c{i:04x}e2 status=200"))
            .collect();
        all(&lines.join("\n"), "data");
    }

    #[test]
    fn number_table_is_data() {
        let rows: Vec<String> = (0..30)
            .map(|i| format!("| {i} | {} | {}.5 |", i * 3, i * 11))
            .collect();
        all(
            &format!("| a | b | c |\n|---|---|---|\n{}", rows.join("\n")),
            "data",
        );
    }

    #[test]
    fn prose_with_dates_and_figures_is_prose() {
        let p = "On 2026-10-19 revenue grew 12.5% to $3.4M, up from $2.9M in Q3 2025. \
                 We shipped v0.54.0 at 05:14 UTC and 1,204 of 1,310 users (91.9%) synced \
                 within 30 s. Costs fell 18% after the 2026-09-26 migration to 2 nodes.";
        assert!(p.len() >= 200);
        all(p, "prose");
    }

    #[test]
    fn german_and_cyrillic_paragraphs_are_prose() {
        all(
            "Der Hund und die Katze spielen im Garten. Über die Brücke gehen täglich \
             viele Menschen zur Arbeit, während die Sonne über der Stadt aufgeht und \
             die Straßen sich langsam füllen.",
            "prose",
        );
        all(
            "Собака и кошка играют в саду. Каждый день много людей идут через мост на \
             работу, пока солнце встаёт над городом и улицы медленно наполняются.",
            "prose",
        );
    }

    #[test]
    fn cjk_paragraphs_are_prose() {
        all(
            "東京は日本の首都であり、世界で最も人口の多い都市圏の一つです。毎日多くの人々が電車で通勤し、\
             街は朝から夜まで活気にあふれています。春には桜が咲き、多くの観光客が訪れます。",
            "prose",
        );
        all(
            "北京是中国的首都，也是一座历史悠久的城市。每天都有很多人乘坐地铁上班，\
             城市从早到晚都充满活力。春天的时候，公园里开满了鲜花，吸引了许多游客。",
            "prose",
        );
    }

    #[test]
    fn cjk_prose_with_inline_code_is_prose() {
        all(
            "今日は`mix test`を実行した。`indexing_test.exs`で3件失敗したので、`plan_chunks`のロジックを\
             見直した。原因は`chunk_rows`の順序で、修正後はすべてのテストが通った。明日は`EmbedNote`の\
             リトライ処理を確認する予定です。",
            "prose",
        );
        all(
            "今天运行了`mix test`，`indexing_test.exs`里有3个测试失败，所以重新检查了`plan_chunks`的逻辑。\
             原因是`chunk_rows`的顺序不对，修复之后所有测试都通过了。明天打算确认`EmbedNote`的重试处理。",
            "prose",
        );
        all(
            "오늘 `mix test`를 실행했더니 `indexing_test.exs`에서 테스트 3개가 실패했다. 그래서 \
             `plan_chunks`의 로직을 다시 살펴보았다. 원인은 `chunk_rows`의 순서였고, 수정한 뒤에는 모든 \
             테스트가 통과했다. 내일은 `EmbedNote`의 재시도 처리를 확인할 예정이다.",
            "prose",
        );
    }

    #[test]
    fn minified_json_with_unicode_values_is_data() {
        let rec =
            r#"{"id":4821,"name":"山田太郎","city":"東京","role":"admin","score":12.5,"ok":true}"#;
        let json = format!("[{}]", [rec; 10].join(","));
        assert!(json.len() >= 200 && json.len() < MAX_CHUNK);
        all(&json, "data");
    }

    fn metrics_table(rows: usize) -> String {
        let rows: Vec<String> = (0..rows)
            .map(|i| {
                format!(
                    "| {i} | {} | {} | {}.{} | {} |",
                    4810 + i * 37,
                    i * 3,
                    i % 4,
                    i % 10,
                    900 + i
                )
            })
            .collect();
        format!(
            "| wk | mrr | new | churn | dau |\n|---|---|---|---|---|\n{}",
            rows.join("\n")
        )
    }

    #[test]
    fn analysis_paragraph_above_a_metrics_table_is_prose() {
        let para = "Revenue grew faster than expected because the annual plan landed in week \
                    three, but churn stayed high among teams that never finished setup. The \
                    onboarding funnel is the next thing to fix, starting with the invite step \
                    that most new admins skip.";
        assert!(para.len() >= 230);
        let note = format!("## Q3 results\n\n{para}\n\n{}", metrics_table(20));
        all(&note, "prose");
        all(&format!("## Q3 results\n\n{}", metrics_table(20)), "data");
    }

    #[test]
    fn fenced_code_is_prose() {
        let code = "```elixir\ndefmodule Foo do\n  def bar(%{id: id} = m, opts \\\\ []) do\n    \
                    {:ok, Map.put(m, :n, id * 2 + Keyword.get(opts, :k, 0))}\n  end\n\n  \
                    def baz([h | t]), do: {h, length(t), Enum.sum(t) / 3}\n  \
                    def qux(<<n::32, r::binary>>), do: {n + 1, byte_size(r) * 8}\nend\n```";
        assert!(code.len() >= 200);
        all(code, "prose");
    }

    // A code block longer than a chunk is cut into pieces with no fence of
    // their own: the fence state carries from the section start.
    #[test]
    fn every_piece_of_a_long_code_block_is_prose() {
        let line = "    let (ct, n) = seal(&K, b\"x\", 7)?;\n";
        let note = format!("```rust\n{}```\n", line.repeat(200));
        assert!(chunk(&note, "", "T").len() >= 3);
        all(&note, "prose");
    }

    #[test]
    fn table_of_words_is_prose() {
        let rows: Vec<&str> = vec![
            "| Alice | engineer | Berlin |",
            "| Bob | designer | Lisbon |",
        ]
        .into_iter()
        .cycle()
        .take(20)
        .collect();
        all(
            &format!("| Name | Role | City |\n|---|---|---|\n{}", rows.join("\n")),
            "prose",
        );
    }

    #[test]
    fn link_lists_and_bold_keys_are_prose() {
        let wikis = [
            "Inbox",
            "Project Alpha",
            "Weekly Review",
            "Reading",
            "Ideas",
        ];
        let note: Vec<String> = (0..4)
            .flat_map(|_| wikis.iter().map(|w| format!("- [[{w}]]")))
            .collect();
        all(&note.join("\n"), "prose");
        let reads = ["Why Rust", "Elixir", "On Writing Well", "Ownership"];
        let note: Vec<String> = (0..3)
            .flat_map(|_| {
                reads
                    .iter()
                    .map(|r| format!("- [{r}](https://example.com/a/b-{})", r.len()))
            })
            .collect();
        all(&note.join("\n"), "prose");
        let keys = ["Owner", "Status", "Due", "Team", "Budget", "Region"];
        let note: Vec<String> = (0..3)
            .flat_map(|_| keys.iter().map(|k| format!("- **{k}:** Alice")))
            .collect();
        all(&note.join("\n"), "prose");
    }

    #[test]
    fn aliased_wikilinks_are_prose() {
        let note: Vec<&str> = std::iter::repeat_n("- [[Inbox|In]]", 20).collect();
        all(&note.join("\n"), "prose");
    }

    const DRAWING: &str = "---\nexcalidraw-plugin: parsed\n---\n\n# Excalidraw Data\n\n## Text Elements\nLaunch plan zanzibar ^abc12345\n\nShip it ^Zz9Yy8Xx\n\n%%\n## Drawing\n```compressed-json\nN4IgLgngDgpiBcIBeA7AHABgOgIwG8AaGmAJwIC2AlgIYAmQAXGAGzBMNwHtqAnAF8D7VkRH0AIgCEAlAAIAKwAUYAXUkBjAGZQAbmwD6mgFYAGAIyWAnAF4A8hCDEAIgGEAEsQDWAMQCkAQVoAVQAIAIgCEfTwBFQKdIgGEfQIBlAAsAdVJALAAEnQBVAH5\n```\n%%\n";

    #[test]
    fn excalidraw_drawing_data_is_dropped_text_kept() {
        let text: String = chunk(DRAWING, "", "T")
            .iter()
            .map(|c| c.0.clone())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(!text.contains("N4IgLgng"), "{text}");
        assert!(
            text.contains("Launch plan zanzibar") && text.contains("Ship it"),
            "{text}"
        );
        assert!(
            !text.contains("^abc12345") && !text.contains("^Zz9Yy8Xx"),
            "{text}"
        );
        assert!(text.contains("excalidraw-plugin"), "{text}");
        let raw = DRAWING.replace(
            "compressed-json\nN4IgLgngDgpiBcIBeA7AHABgOgIwG8AaGm",
            "json\n{\"type\": \"rectangle\", \"x\": 1, \"id\": \"qq\"}\nN4",
        );
        let text: String = chunk(&raw, "", "T").iter().map(|c| c.0.clone()).collect();
        assert!(!text.contains("rectangle"), "{text}");
    }

    #[test]
    fn excalidraw_needs_the_frontmatter_key() {
        let clipped = "---\nsource: https://github.com/zsviczian/obsidian-excalidraw-plugin\n---\n\
                       # Notes\n\n## Drawing\n\nThe API:\n\n```json\n{\"keep\": \"me\"}\n```\n";
        let text: String = chunk(clipped, "", "T")
            .iter()
            .map(|c| c.0.clone())
            .collect();
        assert!(text.contains("keep"), "{text}");
    }

    #[test]
    fn old_format_h1_drawing_is_dropped() {
        let old = DRAWING.replace(
            "## Drawing\n```compressed-json\nN4IgLgngDgpiBcIBeA7AHABgOgIwG8AaGm",
            "# Drawing\n```json\n{\"type\": \"rectangle\", \"x\": 1, \"id\": \"qq\"}\nN4",
        );
        assert!(old.contains("# Drawing\n```json"));
        let text: String = chunk(&old, "", "T").iter().map(|c| c.0.clone()).collect();
        assert!(!text.contains("rectangle"), "{text}");
        assert!(text.contains("Launch plan zanzibar"), "{text}");
    }

    #[test]
    fn json_fences_outside_excalidraw_are_kept() {
        let note = "# T\n\n## Drawing\n```json\n{\"keep\": \"me\"}\n```\n";
        let text: String = chunk(note, "", "T").iter().map(|c| c.0.clone()).collect();
        assert!(text.contains("keep"), "{text}");
    }

    #[test]
    fn short_chunks_are_prose() {
        all("id=1 status=200 2026-10-19", "prose");
    }

    fn sized(n: usize) -> String {
        "word ".repeat(n / 5)
    }

    // Small sections join until a content-defined boundary (H2): the chunk
    // count is 1 + the boundaries among all but the last section.
    #[test]
    fn min512_joins_small_sections() {
        let secs: Vec<String> = (0..12)
            .map(|i| format!("## S{i}\n\n{}", sized(200)))
            .collect();
        let cs = chunk(&secs.join("\n"), "", "T");
        let cuts = secs[..11].iter().filter(|t| boundary(t.trim_end())).count();
        assert!(cuts < 11, "fixture with no join at all");
        assert_eq!(cs.len(), 1 + cuts);
        assert_eq!(cs.iter().map(|c| usize::from(c.3 .1)).sum::<usize>(), 12);
    }

    #[test]
    fn min512_keeps_a_512b_section_alone() {
        let note = format!("## A\n{}\n## B\n{}", sized(600), sized(600));
        assert_eq!(chunk(&note, "", "T").len(), 2);
    }

    // C17: a table never takes a prose section's dense vector away.
    #[test]
    fn data_never_absorbs_prose() {
        let rows: Vec<String> = (0..25).map(|i| format!("| {i} | {} |", i * 7)).collect();
        let table = format!("## Nums\n| a | b |\n|---|---|\n{}", rows.join("\n"));
        assert!(table.len() >= 250 && table.len() < 512);
        let note = format!("{table}\n## Notes\n{}", sized(300));
        let ks = kinds(&note);
        assert_eq!(ks, ["data", "prose"]);
    }

    // A5: the parent of a merged member reaches it through a breadcrumb.
    #[test]
    fn heading_only_parent_reaches_breadcrumb() {
        let cs = chunk("## Setup\n### Linux\nx\n### Mac\ny", "", "T");
        assert_eq!(cs.len(), 1);
        assert!(cs[0].0.lines().any(|l| l == "Setup > Mac"), "{}", cs[0].0);
        assert!(cs[0].2.lines().any(|l| l == "Setup > Mac"));
        assert!(cs[0].1.lines().any(|l| l == "Setup > Mac"));
        // The prefix shows the path both members share (review M1).
        assert_eq!(cs[0].3 .0, ["T", "Setup"]);
        assert_eq!(cs[0].3 .1, 2);
    }

    // A member's own heading is already its first line: a top-level member
    // needs no breadcrumb.
    #[test]
    fn a_top_level_member_gets_no_breadcrumb() {
        let cs = chunk("## A\nx\n## B\ny", "", "T");
        assert_eq!(cs.len(), 1);
        assert_eq!(cs[0].0, "## A\n\nx\n\n## B\n\ny");
    }

    // A12
    #[test]
    fn heading_with_separator_is_one_path_element() {
        let cs = chunk(&format!("# X\n## A > B\n{}", sized(600)), "", "X");
        assert_eq!(cs[0].3 .0, ["X", "A > B"]);
    }

    // A8
    #[test]
    fn skipped_levels_pop_by_level() {
        let note = format!("# H1\n#### H4\n{}\n## H2\n{}", sized(600), sized(600));
        let cs = chunk(&note, "", "T");
        assert_eq!(cs[1].3 .0, ["T", "H1", "H2"]);
    }

    // C5 F6: the folder is a filter, not meaning.
    #[test]
    fn folder_is_not_in_embed_text() {
        let cs = chunk("## A\nbody", "Work/Projects", "T");
        assert!(!cs[0].2.contains("Work/Projects"));
        assert!(cs[0].1.starts_with("Work/Projects > T > A\n\n"));
    }

    // The 512 B cap cut the heading path off (validation W8).
    #[test]
    fn a_long_folder_never_cuts_the_heading() {
        let cs = chunk("## Leaf\nbody", &"f".repeat(900), "T");
        assert!(cs[0].1.len() <= MAX_PREFIX + 2 + cs[0].0.len());
        assert!(cs[0].1.contains("T > Leaf\n\n"), "{}", cs[0].1);
    }

    fn aka(content: &str, aliases: &[&str]) -> Vec<Chunk> {
        let aliases: Vec<String> = aliases.iter().map(|a| a.to_string()).collect();
        let mut out = Vec::new();
        each_chunk(content, "", "T", &aliases, None, |c| out.push(c));
        out
    }

    fn embed_prefix(c: &Chunk) -> &str {
        &c.2[..c.2.len() - c.0.len() - 2]
    }

    #[test]
    fn aliases_join_the_title_in_every_prefix() {
        let cs = aka("## A\nbody\n\n---\n", &["Alpha", "B"]);
        assert_eq!(embed_prefix(&cs[0]), "T (aka Alpha, B) > A");
    }

    #[test]
    fn the_alias_part_is_cut_at_200_chars() {
        let many: Vec<String> = (0..100).map(|i| format!("é{i:03}")).collect();
        let many: Vec<&str> = many.iter().map(String::as_str).collect();
        let cs = aka("body", &many);
        let p = embed_prefix(&cs[0]);
        let part = &p["T (aka ".len()..p.len() - 1];
        assert_eq!(part.chars().count(), 200);
    }

    // B6/A16: 300 aliases and a 2 KB setext heading: the leaf survives.
    #[test]
    fn a_huge_alias_list_never_cuts_the_leaf_heading() {
        let al: Vec<String> = (0..300).map(|i| format!("alias number {i}")).collect();
        let al: Vec<&str> = al.iter().map(String::as_str).collect();
        let setext = format!("{}\n---\n", "leafword ".repeat(230));
        let note = format!("# Top\n## Mid\n### Low\n{setext}\nbody text");
        let cs = aka(&note, &al);
        let p = embed_prefix(&cs[0]);
        assert!(p.len() <= MAX_PREFIX, "{}", p.len());
        assert!(p.starts_with("T (aka alias number 0"), "{p}");
        let leaf = p.rsplit(" > ").next().unwrap();
        assert!(
            leaf.starts_with("leafword leafword") && leaf.len() >= MAX_PREFIX / 2,
            "{p}"
        );
        assert!(cs[0].1.len() - cs[0].0.len() - 2 <= MAX_PREFIX);
    }

    // A13: a link in a heading reads as its text.
    #[test]
    fn heading_text_drops_link_markup() {
        let cs = chunk("## [[Note|Alias]] status\nx", "", "T");
        assert_eq!(cs[0].3 .0, ["T", "Alias status"]);
        let cs = chunk(
            "## **Bold** `code` [site](https://x.io/a) ~~old~~ [[Plain]]\u{200F}\nx",
            "",
            "T",
        );
        assert_eq!(cs[0].3 .0, ["T", "Bold code site old Plain"]);
        assert!(!embed_prefix(&cs[0]).contains("https"));
    }

    // B9: a BOM before the fence is still frontmatter, not a setext H2.
    #[test]
    fn bom_before_frontmatter_is_frontmatter() {
        let cs = chunk("\u{FEFF}---\naliases: [x]\n---\nbody", "", "T");
        let paths: Vec<String> = cs.iter().map(|c| c.3 .0.join(" > ")).collect();
        assert_eq!(paths, ["T", "frontmatter"]);
        assert_eq!(cs[0].0, "body");
    }

    // C7: a query block is not meaning, at any size.
    #[test]
    fn query_fences_are_data() {
        for info in ["dataview", "dataviewjs", "tasks", "query", "base"] {
            let note = format!("## Open\n```{info}\nTABLE file.mtime FROM \"Projects\"\n```");
            assert_eq!(kinds(&note), ["data"], "{info}");
        }
    }

    fn minified_js(bytes: usize) -> String {
        let unit =
            "function(e,t){var n=e.length;if(!n)return t;for(var r=0;r<n;r++)t=e[r](t);return t}";
        format!("```js\n{}\n```", unit.repeat(bytes / unit.len()))
    }

    // C14
    #[test]
    fn minified_js_in_a_fence_gets_no_dense_vector() {
        let cs = chunk(&minified_js(200_000), "", "T");
        assert!(cs.len() > 50 && cs.len() <= budget(200_000));
        assert!(cs.iter().all(|c| c.6 == "data"));
    }

    // C15
    #[test]
    fn a_fenced_log_is_data() {
        let lines: Vec<String> = (0..30)
            .map(|i| format!("2026-10-19T05:14:{i:02}.0863647Z id=7f3c{i:04x}e2 status=200"))
            .collect();
        all(&format!("```\n{}\n```", lines.join("\n")), "data");
    }

    // C13
    #[test]
    fn a_rust_function_stays_prose() {
        let f =
            "```rust\npub fn word_break(text: &str, lo: usize, hi: usize) -> Option<usize> {\n    \
                 let s = &text[lo..hi];\n    s.rfind([' ', '\\n'])\n        \
                 .or_else(|| s.rfind(|c: char| !c.is_alphanumeric()))\n        \
                 .map(|i| lo + i + s[i..].chars().next().map_or(1, char::len_utf8))\n}\n```";
        assert!(f.len() >= 200);
        all(f, "prose");
    }

    // B8 and Q10 (unit): a note of properties alone gets one small dense point.
    #[test]
    fn a_property_only_note_is_dense() {
        let note = "---\nproject: zanzibar\nowner: [Alice, Bob]\ntags: [secret]\ncreated: 2026-01-02\ncount: 3\n---\n";
        let cs = aka(note, &["Z"]);
        assert_eq!(cs.len(), 1);
        assert_eq!(cs[0].6, "frontmatter_dense");
        assert_eq!(cs[0].2, "T (aka Z)\n\nzanzibar\nAlice\nBob");
        assert!(
            cs[0].1.contains("tags: [secret]"),
            "keyword input keeps the raw block"
        );
    }

    #[test]
    fn property_values_are_bounded() {
        let long = "word ".repeat(100);
        let block: String = (0..20).map(|i| format!("k{i}: {long}\n")).collect();
        let cs = chunk(&format!("---\n{block}---\n"), "", "T");
        let values = &cs[0].2["T\n\n".len()..];
        assert!(values.len() <= 1024, "{}", values.len());
        assert!(values.lines().all(|l| l.chars().count() <= 200));
    }

    #[test]
    fn a_note_with_a_body_keeps_frontmatter_keyword_only() {
        assert_eq!(
            kinds("---\nproject: z\n---\nbody"),
            ["prose", "frontmatter"]
        );
    }

    fn led(content: &str, lead: &str) -> Vec<Chunk> {
        let mut out = Vec::new();
        each_chunk(content, "", "T", &[], Some(lead), |c| out.push(c));
        out
    }

    #[test]
    fn the_lead_is_on_the_first_chunk_only() {
        let note = format!("## A\n{}\n## B\n{}", sized(600), sized(600));
        let cs = led(&note, "Playbook: Restore a backup");
        assert!(
            cs[0]
                .2
                .starts_with("T > A\nPlaybook: Restore a backup\n\n## A"),
            "{}",
            cs[0].2
        );
        assert!(cs[0]
            .1
            .starts_with("T > A\nPlaybook: Restore a backup\n\n## A"));
        assert!(cs[1].2.starts_with("T > B\n\n## B"));
        assert!(!cs[0].0.contains("Playbook"), "the lead is not note text");
    }

    #[test]
    fn the_lead_does_not_count_toward_the_body_cap() {
        let body = "word ".repeat(MAX_CHUNK / 5);
        assert!(body.trim().len() <= MAX_CHUNK);
        assert_eq!(led(body.trim(), "Playbook: x").len(), 1);
    }

    #[test]
    fn a_property_only_note_carries_the_lead() {
        let cs = led("---\nproject: zanzibar\n---\n", "Restore a backup");
        assert_eq!(cs[0].2, "T\nRestore a backup\n\nzanzibar");
    }

    /// Wall-time bounds hold in release (CI); debug builds only check
    /// the shape.
    fn within(limit_ms: u128, f: impl FnOnce() -> Vec<Chunk>) -> Vec<Chunk> {
        let t = std::time::Instant::now();
        let out = f();
        let ms = t.elapsed().as_millis();
        assert!(cfg!(debug_assertions) || ms < limit_ms, "{ms} ms");
        out
    }

    // A7
    #[test]
    fn ten_thousand_headings_stay_bounded() {
        let note: String = (0..10_000).map(|i| format!("## h{i}\nx\n")).collect();
        let cs = within(2_000, || chunk(&note, "", "T"));
        assert!(cs.len() <= budget(note.len()), "{}", cs.len());
        assert_eq!(
            cs.iter().map(|c| c.0.matches("\nx").count()).sum::<usize>(),
            10_000
        );
        assert!(cs.iter().all(|c| c.0.len() <= MAX_CHUNK));
    }

    // E1
    #[test]
    fn a_megabyte_line_with_no_space_stays_bounded() {
        let line = "abcdefghij".repeat(100_000);
        let cs = within(1_000, || chunk(&line, "", "T"));
        assert!(cs.len() >= 1_000_000 / MAX_CHUNK);
        assert!(cs.iter().all(|c| c.0.len() <= MAX_CHUNK));
        assert!(cs.iter().all(|c| c.2.len() <= MAX_CHUNK + MAX_PREFIX + 2));
    }

    // D7: every cut (pieces, headings, aliases, prefixes) is on a char
    // boundary; slicing off one would panic.
    #[test]
    fn emoji_are_never_split() {
        let emoji = "🎉🚀✨🧪".repeat(200);
        assert!(emoji.len() >= 3_000);
        let aliases = [emoji.clone()];
        let note = format!("---\ndescription: x\n---\n## {emoji}\n{emoji}\n\n{emoji}");
        let mut cs = Vec::new();
        each_chunk(
            &note,
            &emoji,
            &emoji,
            &aliases,
            Some(cut(&emoji, 400)),
            |c| cs.push(c),
        );
        assert!(!cs.is_empty());
        for c in &cs {
            assert!(c.0.len() <= MAX_CHUNK);
            assert!(c.3 .0.iter().all(|h| h.len() <= MAX_PREFIX));
        }
        let body: usize = cs
            .iter()
            .filter(|c| c.6 != "frontmatter")
            .map(|c| c.0.matches('🎉').count())
            .sum();
        assert!(body >= 400, "{body}");
    }

    /// 30 small sections of distinct prose, about 300 B each.
    fn thirty(i_edit: Option<usize>, extra: &str) -> String {
        (0..30)
            .map(|i| {
                let body: String = (0..40).map(|w| format!("w{}x{} ", i, w)).collect();
                let more = if Some(i) == i_edit { extra } else { "" };
                format!("## Part {i}\n\n{body}{more}")
            })
            .collect::<Vec<_>>()
            .join("\n\n")
    }

    fn unchanged(a: &[Chunk], b: &[Chunk]) -> f64 {
        let after: std::collections::HashSet<&str> = b.iter().map(|c| c.2.as_str()).collect();
        a.iter().filter(|c| after.contains(c.2.as_str())).count() as f64 / a.len() as f64
    }

    // H2: an edit re-groups only its neighbourhood: the chunk it lands in
    // and at most one neighbour it spills into, so at least (n - 2) / n of
    // the chunks (5 of these 7) keep their text and point, and over every
    // single-section edit and insert at least 80% do on average. Greedy
    // packing changed every chunk after the edit (0% kept at the top).
    #[test]
    fn an_edit_regroups_only_its_neighbourhood() {
        let before = chunk(&thirty(None, ""), "", "T");
        let n = before.len();
        assert!(n >= 6, "{n}");
        let (mut worst, mut sum, mut runs) = (1.0f64, 0.0, 0);
        let mut check = |after: Vec<Chunk>| {
            let kept = unchanged(&before, &after);
            worst = worst.min(kept);
            sum += kept;
            runs += 1;
        };
        for i in 0..30 {
            for extra in ["one more sentence about it. ", &"grown text ".repeat(25)] {
                check(chunk(&thirty(Some(i), extra), "", "T"));
            }
            let mut secs: Vec<String> = thirty(None, "")
                .split("\n\n## ")
                .map(str::to_string)
                .collect();
            secs.insert(i.max(1), format!("Inserted {i}\n\nA new short section."));
            check(chunk(&secs.join("\n\n## "), "", "T"));
        }
        let mean = sum / f64::from(runs);
        eprintln!("chunks {n} worst {worst:.3} mean {mean:.3}");
        assert!(worst >= (n - 2) as f64 / n as f64, "worst {worst}");
        assert!(mean >= 0.8, "mean {mean}");
    }

    // L2: config and constant code is code; logs are not.
    #[test]
    fn css_rust_and_json_fences_are_prose_logs_are_data() {
        let css = format!(
            "```css\n{}```",
            ".card {\n  margin: 10px 20px 30px 40px;\n  padding: 4px 8px;\n  border: 1px solid #333;\n  z-index: 100;\n}\n"
                .repeat(4)
        );
        let rust = format!(
            "```rust\n{}```",
            "const TABLE: [u32; 4] = [0x1F2E, 4096, 65535, 1024];\nfn size(n: usize) -> usize { n * 512 + 64 }\n"
                .repeat(4)
        );
        let json = format!(
            "```json\n{}```",
            "{\n  \"port\": 5432,\n  \"host\": \"10.0.20.214\",\n  \"pool_size\": 225,\n  \"timeout_ms\": 30000\n}\n"
                .repeat(4)
        );
        for code in [css, rust, json] {
            assert!(code.len() >= 200);
            all(&code, "prose");
        }
        let log: String = (0..20)
            .map(|i| format!("2026-10-19 05:14:{i:02}.086 [info] 200 GET /api/notes 12.{i}ms\n"))
            .collect();
        all(&format!("```\n{log}```"), "data");
    }

    // M4: a note opening with a query block still feeds the lead to Voyage.
    #[test]
    fn the_lead_skips_a_leading_query_block() {
        let note = format!(
            "## Index\n```dataview\nLIST FROM \"x\"\n```\n## Notes\n{}",
            sized(600)
        );
        let cs = led(&note, "Playbook: Restore");
        assert_eq!(cs[0].6, "data");
        assert!(!cs[0].2.contains("Playbook"));
        assert!(cs[1].2.contains("\nPlaybook: Restore\n\n"), "{}", cs[1].2);
    }

    // M5: a body of data and query blocks only leaves the note reachable
    // by meaning through its frontmatter.
    #[test]
    fn a_body_with_no_prose_makes_the_frontmatter_dense() {
        let cs = led(
            "---\nproject: zanzibar\n---\n```dataview\nLIST\n```\n",
            "Index",
        );
        let kinds: Vec<_> = cs.iter().map(|c| c.6).collect();
        assert_eq!(kinds, ["data", "frontmatter_dense"]);
        assert_eq!(cs[1].2, "T\nIndex\n\nzanzibar");
    }

    #[test]
    fn the_lead_is_capped() {
        let cs = led("body", &"long lead ".repeat(100));
        let lead = cs[0].2.lines().nth(1).unwrap();
        assert!(lead.len() <= MAX_LEAD);
    }

    // L1: `# my_note` in `my_note.md` is the title, not a second heading.
    #[test]
    fn an_underscore_title_h1_is_the_title() {
        let cs = chunk("# my_note\n\nbody", "", "my_note");
        assert_eq!(cs[0].3 .0, ["my_note"]);
    }

    // H3: a BOM before the fence opens frontmatter for chunking, while the
    // shared splitter keeps its contract (CRDT ingest, normalize).
    #[test]
    fn a_bom_is_stripped_for_chunking_only() {
        assert_eq!(
            crate::frontmatter::split("\u{FEFF}---\na: 1\n---\nb".as_bytes()),
            None
        );
        let cs = chunk("\u{FEFF}---\na: 1\n---\nbody", "", "T");
        assert_eq!(cs[0].0, "body");
    }

    #[test]
    fn single_sections_count_one_member() {
        let cs = chunk(&format!("## A\n{}\n---\nx: 1\n", sized(3000)), "", "T");
        assert!(cs.iter().all(|c| c.3 .1 == 1));
    }
}
