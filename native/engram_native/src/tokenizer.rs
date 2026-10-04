//! Keyword tokenizer: NFKC -> lowercase -> strip Latin combining marks ->
//! word runs `[\p{L}\p{N}\p{M}_]+` -> CJK runs to overlapping bigrams, other
//! runs emitted raw, plus their Snowball stem when a language is set.
//!
//! Ported from the Elixir `KeywordIndex.Tokenizer`. Documents AND queries go
//! through this one function, so a term always tokenizes the same way on both
//! sides.
use crate::snowball::algorithms as alg;
use crate::snowball::SnowballEnv;
use regex::Regex;
use std::sync::LazyLock;
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

// Unicode data is Rust's (regex / unicode-normalization / unicode-segmentation),
// NOT the BEAM's. The Elixir tokenizer this replaced classified characters with
// OTP's bundled PCRE 8.45 (2021), which disagrees with current Unicode on ~39k
// codepoints and would have changed under it at the OTP 28 upgrade. Pinning
// the crate versions in Cargo.lock pins the tokenizer.
static STRIP_MARKS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(\p{Latin})\p{Mn}+").unwrap());
static WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[\p{L}\p{N}\p{M}_]+").unwrap());

pub type Stemmer = fn(&mut SnowballEnv) -> bool;

pub const LANGUAGES: &[&str] = &[
    "ar", "ca", "cs", "da", "de", "el", "en", "en_lovins", "en_porter", "eo", "es", "et", "eu",
    "fa", "fi", "fr", "ga", "hi", "hu", "hy", "id", "it", "lt", "ne", "nl", "nl_porter", "no",
    "pl", "pt", "ro", "ru", "sr", "sv", "ta", "tr", "yi",
];

pub fn stemmer(lang: &str) -> Option<Stemmer> {
    Some(match lang {
        "ar" => alg::arabic_stemmer::stem,
        "ca" => alg::catalan_stemmer::stem,
        "cs" => alg::czech_stemmer::stem,
        "da" => alg::danish_stemmer::stem,
        "de" => alg::german_stemmer::stem,
        "el" => alg::greek_stemmer::stem,
        "en" => alg::english_stemmer::stem,
        "en_lovins" => alg::lovins_stemmer::stem,
        "en_porter" => alg::porter_stemmer::stem,
        "eo" => alg::esperanto_stemmer::stem,
        "es" => alg::spanish_stemmer::stem,
        "et" => alg::estonian_stemmer::stem,
        "eu" => alg::basque_stemmer::stem,
        "fa" => alg::persian_stemmer::stem,
        "fi" => alg::finnish_stemmer::stem,
        "fr" => alg::french_stemmer::stem,
        "ga" => alg::irish_stemmer::stem,
        "hi" => alg::hindi_stemmer::stem,
        "hu" => alg::hungarian_stemmer::stem,
        "hy" => alg::armenian_stemmer::stem,
        "id" => alg::indonesian_stemmer::stem,
        "it" => alg::italian_stemmer::stem,
        "lt" => alg::lithuanian_stemmer::stem,
        "ne" => alg::nepali_stemmer::stem,
        "nl" => alg::dutch_stemmer::stem,
        "nl_porter" => alg::dutch_porter_stemmer::stem,
        "no" => alg::norwegian_stemmer::stem,
        "pl" => alg::polish_stemmer::stem,
        "pt" => alg::portuguese_stemmer::stem,
        "ro" => alg::romanian_stemmer::stem,
        "ru" => alg::russian_stemmer::stem,
        "sr" => alg::serbian_stemmer::stem,
        "sv" => alg::swedish_stemmer::stem,
        "ta" => alg::tamil_stemmer::stem,
        "tr" => alg::turkish_stemmer::stem,
        "yi" => alg::yiddish_stemmer::stem,
        _ => return None,
    })
}

fn is_cjk(c: char) -> bool {
    matches!(c as u32, 0x3040..=0x30FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xAC00..=0xD7AF | 0xF900..=0xFAFF)
}

fn script_lang<'a>(token: &str, lang: &'a str) -> &'a str {
    if token.chars().any(|c| ('\u{0400}'..='\u{04FF}').contains(&c)) {
        "ru"
    } else if token.chars().any(|c| ('\u{0370}'..='\u{03FF}').contains(&c)) {
        "el"
    } else if token
        .chars()
        .any(|c| ('\u{0600}'..='\u{06FF}').contains(&c) || ('\u{0750}'..='\u{077F}').contains(&c))
    {
        "ar"
    } else {
        lang
    }
}

pub fn stem(token: &str, lang: &str) -> String {
    let lang = if token.is_ascii() { lang } else { script_lang(token, lang) };
    match stemmer(lang) {
        Some(f) => {
            let mut env = SnowballEnv::create(token);
            f(&mut env);
            env.get_current().into_owned()
        }
        None => token.to_string(),
    }
}

fn emit(token: String, lang: Option<&str>, out: &mut Vec<String>) {
    if let Some(l) = lang {
        let s = stem(&token, l);
        out.push(token);
        if s != *out.last().unwrap() {
            out.push(s);
        }
    } else {
        out.push(token);
    }
}

fn bigrams(g: &[&str], out: &mut Vec<String>) -> usize {
    if g.len() == 1 {
        out.push(g[0].to_string());
        return 1;
    }
    for w in g.windows(2) {
        out.push(format!("{}{}", w[0], w[1]));
    }
    g.len() - 1
}

/// `{tokens, raw_len}` exactly as `Tokenizer.tokens_with_len/2`.
pub fn tokens_with_len(text: &str, lang: Option<&str>) -> (Vec<String>, usize) {
    // Per-char lowercase, NOT `str::to_lowercase`: the latter applies the
    // contextual Greek final-sigma rule (Σ -> ς at word end) and Elixir's
    // `String.downcase(:default)` does not. Different sigma, different token.
    let norm: String = text.nfkc().flat_map(char::to_lowercase).collect();
    // Drop combining marks right after a Latin letter (casefold artifacts like
    // İ -> i + U+0307, and zalgo spam), keeping Arabic/Hebrew marks attached.
    let stripped = STRIP_MARKS.replace_all(&norm, "$1");
    let mut out = Vec::new();
    let mut raw = 0;
    for word in WORD.find_iter(&stripped).map(|m| m.as_str()) {
        if !word.chars().any(is_cjk) {
            emit(word.to_string(), lang, &mut out);
            raw += 1;
            continue;
        }
        let graphemes: Vec<&str> = word.graphemes(true).collect();
        let mut i = 0;
        while i < graphemes.len() {
            let cjk = graphemes[i].chars().any(is_cjk);
            let mut j = i + 1;
            while j < graphemes.len() && graphemes[j].chars().any(is_cjk) == cjk {
                j += 1;
            }
            if cjk {
                raw += bigrams(&graphemes[i..j], &mut out);
            } else {
                emit(graphemes[i..j].concat(), lang, &mut out);
                raw += 1;
            }
            i = j;
        }
    }
    (out, raw)
}
