//! `Frontmatter.parse/1` for the common shape of a frontmatter block, ported
//! as rules (like meta.rs), not a YAML parser. The definition stays
//! YamlElixir (yamerl, core schema): this module only answers when it is sure
//! of yamerl's result, and returns None for anything else so the caller falls
//! back to YamlElixir. Pinned by test/engram/native/frontmatter_parse_test.exs,
//! which diffs both on generated blocks.
//!
//! Accepted: column-0 `key: value` lines, where the value is a one-line plain,
//! single- or double-quoted scalar, a one-line flow list of such scalars, or
//! empty (null, or a block list of one-line scalars below it); blank and
//! comment lines. Everything else (nested maps, block or multi-line scalars,
//! anchors, tags, floats, directives, tabs, CR, duplicate keys) is None.
//!
//! Output: `(key, value as JSON)` in source order, the JSON exactly as
//! `Jason.encode/1` prints the YamlElixir term.
//!
//! `emit_key` is the other direction, `Frontmatter.emit/3`'s per-key Ymlr
//! render, ported rule for rule from Ymlr 5.1 (`Ymlr.Encode`): same
//! contract, None (render in Elixir) where unsure. Its output must match
//! Ymlr byte for byte, since `content_hash` is taken over it.
use regex::Regex;
use serde::de::{Deserialize, Deserializer, MapAccess, SeqAccess, Visitor};
use std::collections::HashSet;
use std::fmt;
use std::sync::OnceLock;

/// The block's keys and JSON values in source order, or None: ask YamlElixir.
pub fn parse(block: &str) -> Option<Vec<(String, String)>> {
    if !block.chars().all(allowed) {
        return None;
    }
    let lines: Vec<&str> = block.split('\n').collect();
    let mut out: Vec<(String, String)> = Vec::new();
    let mut seen = HashSet::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        if skippable(line) {
            i += 1;
            continue;
        }
        if line.starts_with(' ') || line.starts_with("---") || line.starts_with("...") {
            return None;
        }
        let colon = line.find(':')?;
        let key = &line[..colon];
        let rest = &line[colon + 1..];
        if !(rest.is_empty() || rest.starts_with(' ')) || !plain_key(key) {
            return None;
        }
        let value = rest.trim_start_matches(' ');
        let json = if value.is_empty() || value.starts_with('#') {
            let (json, next) = block_list(&lines, i + 1)?;
            i = next;
            json
        } else {
            i += 1;
            scalar_or_list(value)?
        };
        if !seen.insert(key) {
            return None;
        }
        out.push((key.to_string(), json));
    }
    Some(out)
}

/// Chars yamerl reads without question: printable, no tab, CR, NEL, line or
/// paragraph separators, BOM or C1 controls.
fn allowed(c: char) -> bool {
    matches!(c, '\n' | ' '..='~' | '\u{A0}'..='\u{D7FF}' | '\u{E000}'..='\u{FFFD}' | '\u{10000}'..)
        && !matches!(c, '\u{2028}' | '\u{2029}' | '\u{FEFF}')
}

/// Blank or comment-only line.
fn skippable(line: &str) -> bool {
    let t = line.trim_start_matches(' ');
    t.is_empty() || t.starts_with('#')
}

/// A key the rules can read: plain, a string under the core schema, not the
/// `<<` merge key, short enough to be an implicit key, and found by
/// `top_level_key_order/2`'s `^([^\s:][^:]*):` exactly as written.
fn plain_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 512
        && !key.ends_with(' ')
        && key != "<<"
        && !key.starts_with(['-', '?', ':'])
        && !key.contains(|c| "[]{},#&*!|>'\"%@`".contains(c))
        && matches!(resolve(key), Some(Value::Str))
}

/// An empty-valued key: the block list on the lines from `from`, or null.
/// Returns the JSON and the first line after it.
fn block_list(lines: &[&str], from: usize) -> Option<(String, usize)> {
    let mut items: Vec<String> = Vec::new();
    let mut indent = None;
    let mut j = from;
    while j < lines.len() {
        let line = lines[j];
        if skippable(line) {
            j += 1;
            continue;
        }
        let t = line.trim_start_matches(' ');
        let ind = line.len() - t.len();
        let item = if t == "-" {
            ""
        } else if let Some(item) = t.strip_prefix("- ") {
            item.trim_start_matches(' ')
        } else if ind == 0 {
            break;
        } else {
            return None;
        };
        if *indent.get_or_insert(ind) != ind {
            return None;
        }
        if item.is_empty() || item.starts_with('#') {
            items.push("null".to_string());
        } else {
            items.push(scalar(item, false)?);
        }
        j += 1;
    }
    let json = if items.is_empty() {
        "null".to_string()
    } else {
        format!("[{}]", items.join(","))
    };
    Some((json, j))
}

fn scalar_or_list(value: &str) -> Option<String> {
    match value.strip_prefix('[') {
        Some(inner) => flow_list(inner),
        None => scalar(value, false),
    }
}

/// `[a, 'b', "c"]` on one line, given the text after `[`.
fn flow_list(mut s: &str) -> Option<String> {
    let mut items: Vec<String> = Vec::new();
    s = s.trim_start_matches(' ');
    if let Some(rest) = s.strip_prefix(']') {
        return after_value(rest).then(|| "[]".to_string());
    }
    loop {
        let (json, rest) = flow_item(s)?;
        items.push(json);
        let rest = rest.trim_start_matches(' ');
        if let Some(rest) = rest.strip_prefix(',') {
            s = rest.trim_start_matches(' ');
            // `[a,]` and `[a,,b]`: unsure, ask yamerl.
            if s.starts_with([',', ']']) || s.is_empty() {
                return None;
            }
        } else if let Some(rest) = rest.strip_prefix(']') {
            return after_value(rest).then(|| format!("[{}]", items.join(",")));
        } else {
            return None;
        }
    }
}

/// One flow item: (JSON, text after it).
fn flow_item(s: &str) -> Option<(String, &str)> {
    if s.starts_with(['"', '\'']) {
        let (text, rest) = quoted(s)?;
        return Some((json_string(&text), rest));
    }
    let end = s.find([',', ']']).unwrap_or(s.len());
    let item = s[..end].trim_end_matches(' ');
    if item.contains(|c| "[]{}#:".contains(c)) {
        return None;
    }
    Some((scalar(item, true)?, &s[end..]))
}

/// What may follow a complete value on its line: blanks, then a comment.
fn after_value(rest: &str) -> bool {
    let t = rest.trim_start_matches(' ');
    t.is_empty() || (t.starts_with('#') && t.len() < rest.len())
}

/// A one-line scalar as JSON. `flow`: `s` is a whole flow item, already
/// trimmed and free of comments.
fn scalar(s: &str, flow: bool) -> Option<String> {
    if s.starts_with(['"', '\'']) {
        let (text, rest) = quoted(s)?;
        return (flow || after_value(rest)).then(|| json_string(&text));
    }
    let first = s.chars().next()?;
    if "[]{},#&*!|>'\"%@`?:".contains(first) {
        return None;
    }
    // `-x` is plain; `- x` and a lone `-` are not.
    if first == '-' && (s.len() == 1 || s[1..].starts_with([' ', ',', ']'])) {
        return None;
    }
    let plain = if flow {
        s
    } else {
        let end = s.find(" #").unwrap_or(s.len());
        s[..end].trim_end_matches(' ')
    };
    if plain.contains(": ") || plain.ends_with(':') {
        return None;
    }
    match resolve(plain)? {
        Value::Null => Some("null".to_string()),
        Value::Bool(b) => Some(b.to_string()),
        Value::Int(i) => Some(i.to_string()),
        Value::Str => Some(json_string(plain)),
    }
}

enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Str,
}

/// yamerl's core-schema resolution of a plain scalar (null, bool, int,
/// float, str, tried in that order). None where the rules stop: floats
/// (Erlang's float printing is not reproduced here), hex/octal and huge
/// ints, and yamerl's `+`/`-`/`0x` quirks (it reads a bare sign as 0).
fn resolve(s: &str) -> Option<Value> {
    static FLOAT: OnceLock<Regex> = OnceLock::new();
    match s {
        "" | "~" | "null" | "Null" | "NULL" => return Some(Value::Null),
        "true" | "True" | "TRUE" => return Some(Value::Bool(true)),
        "false" | "False" | "FALSE" => return Some(Value::Bool(false)),
        _ => {}
    }
    let (neg, body) = match s.as_bytes()[0] {
        b'-' => (true, &s[1..]),
        b'+' => (false, &s[1..]),
        _ => (false, s),
    };
    if body.is_empty() || body.starts_with("0x") || body.starts_with("0o") {
        return None;
    }
    if body.bytes().all(|b| b.is_ascii_digit()) {
        let digits = body.trim_start_matches('0');
        if digits.len() > 18 {
            return None;
        }
        let n: i64 = if digits.is_empty() {
            0
        } else {
            digits.parse().ok()?
        };
        return Some(Value::Int(if neg { -n } else { n }));
    }
    let float = FLOAT
        .get_or_init(|| Regex::new(r"\A(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?\z").unwrap());
    if float.is_match(body) || matches!(body, ".nan" | ".NaN" | ".NAN" | ".inf" | ".Inf" | ".INF") {
        return None;
    }
    Some(Value::Str)
}

/// A one-line quoted scalar at the start of `s`: (text, rest of line).
fn quoted(s: &str) -> Option<(String, &str)> {
    let mut out = String::new();
    if let Some(body) = s.strip_prefix('\'') {
        let mut chars = body.char_indices();
        while let Some((i, c)) = chars.next() {
            if c == '\'' {
                if body[i + 1..].starts_with('\'') {
                    chars.next();
                    out.push('\'');
                } else {
                    return Some((out, &body[i + 1..]));
                }
            } else {
                out.push(c);
            }
        }
        return None;
    }
    let body = s.strip_prefix('"')?;
    let mut chars = body.char_indices();
    while let Some((i, c)) = chars.next() {
        match c {
            '"' => return Some((out, &body[i + 1..])),
            '\\' => {
                let (_, e) = chars.next()?;
                out.push(match e {
                    '"' => '"',
                    '\\' => '\\',
                    '/' => '/',
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    'b' => '\u{8}',
                    'f' => '\u{C}',
                    'u' => {
                        let hex: String = (0..4)
                            .map(|_| chars.next().map(|x| x.1))
                            .collect::<Option<_>>()?;
                        if !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
                            return None;
                        }
                        // None for a surrogate half; controls: unsure, ask yamerl.
                        let c = char::from_u32(u32::from_str_radix(&hex, 16).ok()?)?;
                        if c < ' ' {
                            return None;
                        }
                        c
                    }
                    _ => return None,
                });
            }
            c => out.push(c),
        }
    }
    None
}

/// `Jason.encode/1` of a string: `"`, `\` and the five named controls
/// escaped, other controls as `\u00XX` (uppercase hex), everything else raw.
fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => out.push_str("\\r"),
            '\u{8}' => out.push_str("\\b"),
            '\u{C}' => out.push_str("\\f"),
            c if c < ' ' => out.push_str(&format!("\\u{:04X}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// A decoded Y.Map value, as `Jason.decode/1` would give it, restricted to
/// what `emit_key` renders: no floats, objects with unique keys.
enum Json {
    Null,
    Bool(bool),
    Int(i128),
    Str(String),
    List(Vec<Json>),
    // Keys in Erlang term order (bytewise), as Ymlr enumerates a small map.
    Object(Vec<(String, Json)>),
    // Anything emit_key declines: floats, repeated keys.
    Unsure,
}

impl<'de> Deserialize<'de> for Json {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Json, D::Error> {
        d.deserialize_any(JsonVisitor)
    }
}

struct JsonVisitor;

impl<'de> Visitor<'de> for JsonVisitor {
    type Value = Json;

    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("any JSON value")
    }
    fn visit_unit<E>(self) -> Result<Json, E> {
        Ok(Json::Null)
    }
    fn visit_bool<E>(self, b: bool) -> Result<Json, E> {
        Ok(Json::Bool(b))
    }
    fn visit_i64<E>(self, i: i64) -> Result<Json, E> {
        Ok(Json::Int(i.into()))
    }
    fn visit_u64<E>(self, u: u64) -> Result<Json, E> {
        Ok(Json::Int(u.into()))
    }
    fn visit_f64<E>(self, _: f64) -> Result<Json, E> {
        Ok(Json::Unsure)
    }
    fn visit_str<E>(self, s: &str) -> Result<Json, E> {
        Ok(Json::Str(s.to_string()))
    }
    fn visit_string<E>(self, s: String) -> Result<Json, E> {
        Ok(Json::Str(s))
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Json, A::Error> {
        let mut items = Vec::new();
        while let Some(item) = seq.next_element()? {
            items.push(item);
        }
        Ok(Json::List(items))
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Json, A::Error> {
        let mut pairs: Vec<(String, Json)> = Vec::new();
        while let Some(key) = map.next_key::<String>()? {
            pairs.push((key, map.next_value()?));
        }
        pairs.sort_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
        // A repeated key, or a map past 32 keys (the BEAM then iterates in
        // hash order, which Ymlr follows), is left to Elixir.
        if pairs.windows(2).any(|w| w[0].0 == w[1].0) || pairs.len() > 32 {
            return Ok(Json::Unsure);
        }
        Ok(Json::Object(pairs))
    }
}

/// `Frontmatter.emit_key/2` for a key whose stored value is `value`:
/// `Ymlr.document!(%{key => Jason.decode!(value)})` minus its `---\n`.
/// None: not JSON, or a shape these rules do not render; Elixir then does.
pub fn emit_key(key: &str, value: &str) -> Option<String> {
    let json: Json = serde_json::from_str(value).ok()?;
    let mut out = String::with_capacity(key.len() + value.len() + 8);
    map_entry(&mut out, key, &json, 0)?;
    out.push('\n');
    Some(out)
}

fn indent(out: &mut String, level: usize) {
    out.push('\n');
    for _ in 0..level {
        out.push_str("  ");
    }
}

/// `Ymlr.Encode.map/3`'s entry for (key, value) in a map at `level`.
fn map_entry(out: &mut String, key: &str, v: &Json, level: usize) -> Option<()> {
    string(out, key, None)?;
    out.push(':');
    match v {
        Json::Null => {}
        Json::List(items) if items.is_empty() => out.push_str(" []"),
        Json::Object(pairs) if pairs.is_empty() => out.push_str(" {}"),
        Json::Object(_) | Json::List(_) => {
            indent(out, level);
            out.push_str("  ");
            value(out, v, level + 1)?;
        }
        _ => {
            out.push(' ');
            value(out, v, level + 1)?;
        }
    }
    Some(())
}

/// `Ymlr.Encoder.encode/3`.
fn value(out: &mut String, v: &Json, level: usize) -> Option<()> {
    match v {
        Json::Null | Json::Unsure => return None,
        Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Json::Int(i) => out.push_str(&i.to_string()),
        Json::Str(s) => string(out, s, Some(level))?,
        Json::List(items) if items.is_empty() => out.push_str("[]"),
        Json::Object(pairs) if pairs.is_empty() => out.push_str("{}"),
        Json::List(items) => {
            for (n, item) in items.iter().enumerate() {
                if n > 0 {
                    indent(out, level);
                }
                match item {
                    Json::Null => out.push('-'),
                    Json::Str(s) if s.is_empty() => out.push_str("- \"\""),
                    item => {
                        out.push_str("- ");
                        value(out, item, level + 1)?;
                    }
                }
            }
        }
        Json::Object(pairs) => {
            for (n, (k, item)) in pairs.iter().enumerate() {
                if n > 0 {
                    indent(out, level);
                }
                map_entry(out, k, item, level)?;
            }
        }
    }
    Some(())
}

const EXACT_SINGLE: &[&str] = &[
    "", "~", "?", "-", "null", "Null", "NULL", "y", "Y", "n", "N", "yes", "Yes", "YES", "no", "No",
    "NO", "true", "True", "TRUE", "false", "False", "FALSE", "on", "On", "ON", "off", "Off", "OFF",
];

const START_SINGLE: &[&str] = &[
    " ", "\t", "!", "&", "*", "{", "}", "[", "]", ",", "#", "|", ">", "@", "`", "\"", "- ", ": ",
    ":{", "%", "? ", "0b", "0o", "0x", ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF", "-.inf",
    "-.Inf", "-.INF", ".nan", ".Nan", ".NAN",
];

#[derive(Clone, Copy, PartialEq)]
enum Quote {
    Plain,
    MaybeDouble,
    Single,
    Double,
    Multiline,
}

fn printable(c: char) -> bool {
    matches!(c, ' '..='~' | '\t' | '\n' | '\u{85}' | '\u{A0}'..='\u{FFFD}' | '\u{10000}'..)
}

/// The escape letter for chars Ymlr writes as `\x` inside double quotes.
fn escape_letter(c: char) -> Option<char> {
    Some(match c {
        '\u{7}' => 'a',
        '\u{8}' => 'b',
        '\u{1B}' => 'e',
        '\u{C}' => 'f',
        '\r' => 'r',
        '\u{B}' => 'v',
        '\0' => '0',
        '\u{A0}' => '_',
        '\u{85}' => 'N',
        '\u{2028}' => 'L',
        '\u{2029}' => 'P',
        '"' => '"',
        '\\' => '\\',
        _ => return None,
    })
}

fn forces_double(c: char) -> bool {
    !printable(c) || (escape_letter(c).is_some() && c != '"' && c != '\\')
}

/// `Ymlr.Encode`'s `numeric?/1`: `Float.parse(s)` consumes all of `s`,
/// i.e. `[-+]?\d+(\.\d+)?([eE][-+]?\d+)?`. None where Erlang's float range
/// decides: Float.parse/1 fails on overflow, and up to 300 chars, or 200 with
/// an exponent of at most 99, stays well inside it. Hand-written: a regex
/// with captures cost ~1 us per string here.
fn numeric(s: &str) -> Option<bool> {
    let b = s.as_bytes();
    let digits = |mut i: usize| {
        let start = i;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        (i > start).then_some(i)
    };
    let mut i = usize::from(matches!(b.first(), Some(b'-' | b'+')));
    let Some(mut j) = digits(i) else {
        return Some(false);
    };
    if b.get(j) == Some(&b'.') {
        match digits(j + 1) {
            Some(k) => j = k,
            None => return Some(false),
        }
    }
    if j == b.len() {
        return (s.len() <= 300).then_some(true);
    }
    if !matches!(b[j], b'e' | b'E') {
        return Some(false);
    }
    i = j + 1 + usize::from(matches!(b.get(j + 1), Some(b'-' | b'+')));
    match digits(i) {
        Some(k) if k == b.len() => {
            let exp = s[i..].trim_start_matches('0').len();
            (s.len() <= 200 && exp <= 2).then_some(true)
        }
        _ => Some(false),
    }
}

/// `Ymlr.Encode.encode_binary/2`. `level` None: a map key.
fn string(out: &mut String, s: &str, level: Option<usize>) -> Option<()> {
    if s.len() <= 5 && EXACT_SINGLE.contains(&s) {
        out.push('\'');
        out.push_str(s);
        out.push('\'');
        return Some(());
    }
    if s == "\n" {
        out.push_str("\"\\n\"");
        return Some(());
    }
    let special_start = s
        .bytes()
        .next()
        .is_some_and(|c| b" \t!&*{}[],#|>@`\"-:%?0.+".contains(&c));
    let prefix = || START_SINGLE.iter().find(|p| s.starts_with(**p));
    let kind = if let Some(rest) = s.strip_prefix('\'') {
        scan(rest, Quote::Double)
    } else if let Some(p) = special_start.then(prefix).flatten() {
        scan(&s[p.len()..], Quote::Single)
    } else if numeric(s)? {
        Quote::Single
    } else {
        scan(s, Quote::Plain)
    };
    match kind {
        Quote::Plain | Quote::MaybeDouble => out.push_str(s),
        Quote::Single => {
            out.push('\'');
            out.push_str(s);
            out.push('\'');
        }
        Quote::Double => {
            out.push('"');
            for c in s.chars() {
                match escape_letter(c) {
                    Some(e) => {
                        out.push('\\');
                        out.push(e);
                    }
                    None if !printable(c) => {
                        let n = c as u32;
                        out.push_str(&if n <= 0xFF {
                            format!("\\x{n:02X}")
                        } else if n <= 0xFFFF {
                            format!("\\u{n:04X}")
                        } else {
                            format!("\\U{n:06X}")
                        });
                    }
                    None => out.push(c),
                }
            }
            out.push('"');
        }
        Quote::Multiline => {
            // A multi-line map key is `inspect/1`d: leave it to Elixir.
            let level = level?.max(1);
            out.push_str(if s.ends_with("\n\n") {
                "|+"
            } else if s.ends_with('\n') {
                "|"
            } else {
                "|-"
            });
            for line in s.strip_suffix('\n').unwrap_or(s).split('\n') {
                if line.is_empty() {
                    out.push('\n');
                } else {
                    indent(out, level);
                    out.push_str(line);
                }
            }
        }
    }
    Some(())
}

/// `do_string_encoding_type/2`: scan `s` from state `q`. Bytewise: every
/// char that steers the state is ASCII except the non-printable and
/// escape-letter ones, which only ever force double quotes.
fn scan(s: &str, mut q: Quote) -> Quote {
    let b = s.as_bytes();
    let quoted_by = |q: Quote| match q {
        Quote::Double | Quote::MaybeDouble => Quote::Double,
        _ => Quote::Single,
    };
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        if c >= 0x80 {
            let ch = s[i..].chars().next().unwrap_or(' ');
            if forces_double(ch) {
                q = Quote::Double;
            }
            i += ch.len_utf8();
            continue;
        }
        match c {
            b'\n' => return Quote::Multiline,
            b'\t' => {}
            0..=0x1F | 0x7F => q = Quote::Double,
            b'\'' => {
                q = if q == Quote::Plain {
                    Quote::MaybeDouble
                } else {
                    Quote::Double
                }
            }
            b' ' if b.get(i + 1) == Some(&b'#') => {
                q = quoted_by(q);
                i += 2;
                continue;
            }
            b':' if b.get(i + 1) == Some(&b' ') => {
                q = quoted_by(q);
                i += 2;
                continue;
            }
            b' ' | b':' if i + 1 == b.len() => return quoted_by(q),
            _ => {}
        }
        if c == b'\t' && i + 1 == b.len() {
            return quoted_by(q);
        }
        i += 1;
    }
    q
}

#[cfg(test)]
mod tests {
    use super::parse;

    fn kv(pairs: &[(&str, &str)]) -> Option<Vec<(String, String)>> {
        Some(
            pairs
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        )
    }

    #[test]
    fn common_shapes() {
        let b = "title: \"A: b\"\ntags:\n  - x\n  - 'y'\naliases: [a, \"b c\"]\nn: 4\nd: 2024-01-01\ne:\n";
        assert_eq!(
            parse(b),
            kv(&[
                ("title", "\"A: b\""),
                ("tags", "[\"x\",\"y\"]"),
                ("aliases", "[\"a\",\"b c\"]"),
                ("n", "4"),
                ("d", "\"2024-01-01\""),
                ("e", "null"),
            ])
        );
    }

    #[test]
    fn unsure_shapes_fall_back() {
        for b in [
            "a:\n  b: c\n",
            "a: |\n  x\n",
            "a: 1.5\n",
            "a: &x 1\n",
            "a: 1\na: 2\n",
            "a:\tb\n",
            "a: b\r\n",
            "- a\n",
            "a: b: c\n",
            "a: [b,]\n",
            "a: \"x\n",
        ] {
            assert_eq!(parse(b), None, "{b:?}");
        }
    }

    #[test]
    fn emit_matches_ymlr_on_known_cases() {
        use super::emit_key;
        let cases = [
            ("title", "\"My note: a test\"", "title: 'My note: a test'\n"),
            ("tags", "[\"a\",null,\"\"]", "tags:\n  - a\n  -\n  - \"\"\n"),
            ("n", "null", "'n':\n"),
            ("k", "null", "k:\n"),
            ("e", "[]", "e: []\n"),
            ("b", "\"yes\"", "b: 'yes'\n"),
            ("s", "\"it's\"", "s: it's\n"),
            ("q", "\"it's: x\"", "q: \"it's: x\"\n"),
            ("m", "\"a\\nb\\n\"", "m: |\n  a\n  b\n"),
            (
                "o",
                "{\"b\":1,\"a\":[true]}",
                "o:\n  a:\n    - true\n  b: 1\n",
            ),
            ("x", "\"5\"", "x: '5'\n"),
            ("c", "\"a\\u0001\"", "c: \"a\\x01\"\n"),
        ];
        for (k, v, want) in cases {
            assert_eq!(emit_key(k, v).as_deref(), Some(want), "{k}: {v}");
        }
        for v in ["1.5", "not json", "{\"a\":1,\"a\":2}"] {
            assert_eq!(emit_key("k", v), None, "{v}");
        }
        assert_eq!(emit_key("a\nb", "1"), None);
    }

    #[test]
    fn linear_in_block_size() {
        // 4 MB of list items: a quadratic rescan would take minutes, linear
        // well under a second; the limit only catches the former.
        let b = format!("tags:\n{}", "  - item\n".repeat(450_000));
        let t = std::time::Instant::now();
        assert!(parse(&b).is_some());
        assert!(t.elapsed().as_secs() < 5, "{:?}", t.elapsed());
    }
}
