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
use regex::Regex;
use std::collections::HashSet;
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
    fn linear_in_block_size() {
        // 4 MB of list items: a quadratic rescan would take minutes, linear
        // well under a second; the limit only catches the former.
        let b = format!("tags:\n{}", "  - item\n".repeat(450_000));
        let t = std::time::Instant::now();
        assert!(parse(&b).is_some());
        assert!(t.elapsed().as_secs() < 5, "{:?}", t.elapsed());
    }
}
