//! In-house NIFs. Each is a pure function over binaries, runs on a dirty CPU
//! scheduler, and returns BEAM binaries (so its OUTPUT is visible to
//! `:erlang.memory(:binary)`). See docs/context for the memory standard.
mod links;
mod memory;
mod meta;
mod mmr;
mod vectors;
mod tokenizer;

// Not under `cargo test`: enif_alloc only exists inside a running BEAM.
#[cfg(not(test))]
#[global_allocator]
static ALLOCATOR: memory::Counting = memory::Counting;

use hmac::{Hmac, Mac};
use rustler::{Binary, Encoder, Env, Error, ListIterator, NewBinary, NifResult, Term};
use sha2::Sha256;
use std::collections::HashMap;

const K1: f64 = 1.2;
const B: f64 = 0.75;
// Same bound and reason as QdrantSparse's @memo_max.
const MEMO_MAX: usize = 20_000;

fn dim(key: &[u8], token: &str) -> u32 {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("hmac accepts any key length");
    mac.update(token.as_bytes());
    let out = mac.finalize().into_bytes();
    u32::from_be_bytes([out[0], out[1], out[2], out[3]])
}

/// One chunk -> (u32 LE indices sorted ascending, f64 LE values, raw doc_len).
fn encode(text: &str, key: &[u8], avgdl: f64, lang: Option<&str>, memo: &mut HashMap<String, u32>) -> (Vec<u8>, Vec<u8>, usize) {
    let (tokens, doc_len) = tokenizer::tokens_with_len(text, lang);
    let norm = (1.0 - B) + B * (doc_len as f64) / avgdl;

    let mut tf: HashMap<&str, u32> = HashMap::new();
    for t in &tokens {
        *tf.entry(t.as_str()).or_insert(0) += 1;
    }

    let mut by_dim: HashMap<u32, f64> = HashMap::with_capacity(tf.len());
    for (token, n) in tf {
        let d = match memo.get(token) {
            Some(d) => *d,
            None => {
                let d = dim(key, token);
                if memo.len() < MEMO_MAX {
                    memo.insert(token.to_string(), d);
                }
                d
            }
        };
        let n = n as f64;
        let w = n * (K1 + 1.0) / (n + K1 * norm);
        *by_dim.entry(d).or_insert(0.0) += w;
    }

    let mut pairs: Vec<(u32, f64)> = by_dim.into_iter().collect();
    pairs.sort_unstable_by_key(|p| p.0);
    let mut idx = Vec::with_capacity(pairs.len() * 4);
    let mut val = Vec::with_capacity(pairs.len() * 8);
    for (d, w) in pairs {
        idx.extend_from_slice(&d.to_le_bytes());
        val.extend_from_slice(&w.to_le_bytes());
    }
    (idx, val, doc_len)
}

fn to_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Binary<'a> {
    let mut b = NewBinary::new(env, bytes.len());
    b.as_mut_slice().copy_from_slice(bytes);
    b.into()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn encode_documents_nif<'a>(
    env: Env<'a>,
    texts: Vec<Binary<'a>>,
    key: Binary<'a>,
    avgdl: f64,
    lang: Option<String>,
) -> (Vec<(Binary<'a>, Binary<'a>, usize)>, usize) {
    let base = memory::begin();
    let mut memo = HashMap::new();
    let out = texts
        .iter()
        .map(|t| {
            let text = String::from_utf8_lossy(t.as_slice());
            let (i, v, n) = encode(&text, key.as_slice(), avgdl, lang.as_deref(), &mut memo);
            (to_binary(env, &i), to_binary(env, &v), n)
        })
        .collect();
    drop(memo);
    (out, memory::peak_since(base))
}

/// Query vector: distinct tokens, value 1.0 each (Qdrant applies IDF).
/// Plain lists: a query is a few terms and goes straight into a JSON body.
/// Dirty like the rest: query length is caller-controlled.
#[rustler::nif(schedule = "DirtyCpu")]
fn encode_query_nif(query: &str, key: Binary, lang: Option<String>) -> (Vec<u32>, Vec<f64>) {
    let (tokens, _) = tokenizer::tokens_with_len(query, lang.as_deref());
    let mut dims: Vec<u32> = tokens.iter().map(|t| dim(key.as_slice(), t)).collect();
    dims.sort_unstable();
    dims.dedup();
    let values = vec![1.0; dims.len()];
    (dims, values)
}

/// Language codes with a Snowball stemmer.
#[rustler::nif]
fn stem_languages() -> Vec<&'static str> {
    tokenizer::LANGUAGES.to_vec()
}

/// Live bytes held by this library's Rust heap, process-wide.
#[rustler::nif]
fn live_bytes() -> isize {
    memory::live_bytes()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tokens_with_len(text: &str, lang: Option<String>) -> (Vec<String>, usize) {
    tokenizer::tokens_with_len(text, lang.as_deref())
}

// The note parsers come in two schedules. A note up to `Engram.Native`'s
// @inline_max (16 KB) parses in well under a millisecond (adversarial input,
// growing backtick runs, measured 2.8 ms for title plus tags) and runs on the
// calling scheduler: no hop, and no queueing behind a long keyword encode
// on prod's single dirty CPU scheduler. Bigger notes go dirty.

/// `Links.Parser.extract/1`: `{[{position, kind, target_start, target_len,
/// target, alias, anchor}], scrub_count}`, and the call's native peak. Each
/// link is encoded as a term the moment it is built, so the output never
/// exists as a Rust copy. Linear in the note; no size bound, notes of any
/// size must index.
fn link_extract<'a>(env: Env<'a>, content: &str) -> ((Vec<Term<'a>>, usize), usize) {
    let base = memory::begin();
    let mut terms = Vec::new();
    let scrubs = links::extract(content, |(pos, kind, ts, tl, target, alias, anchor)| {
        terms.push((pos, kind, ts, tl, target.as_ref(), alias, anchor.as_deref()).encode(env));
    });
    let peak = memory::peak_since(base);
    ((terms, scrubs), peak)
}

/// `Helpers.extract_title/2` without the file-name fallback, and the peak.
fn note_title(content: &str) -> (Option<String>, usize) {
    let base = memory::begin();
    let out = meta::title(content);
    (out, memory::peak_since(base))
}

/// `Helpers.extract_tags/1`, and the peak.
fn note_tags<'a>(env: Env<'a>, content: &str) -> (Vec<Term<'a>>, usize) {
    let base = memory::begin();
    let mut out = Vec::new();
    meta::tags(content, |t| out.push(t.encode(env)));
    (out, memory::peak_since(base))
}

#[rustler::nif]
fn link_extract_nif<'a>(env: Env<'a>, content: &str) -> ((Vec<Term<'a>>, usize), usize) {
    link_extract(env, content)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn link_extract_dirty_nif<'a>(env: Env<'a>, content: &str) -> ((Vec<Term<'a>>, usize), usize) {
    link_extract(env, content)
}

#[rustler::nif]
fn note_title_nif(content: &str) -> (Option<String>, usize) {
    note_title(content)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn note_title_dirty_nif(content: &str) -> (Option<String>, usize) {
    note_title(content)
}

#[rustler::nif]
fn note_tags_nif<'a>(env: Env<'a>, content: &str) -> (Vec<Term<'a>>, usize) {
    note_tags(env, content)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn note_tags_dirty_nif<'a>(env: Env<'a>, content: &str) -> (Vec<Term<'a>>, usize) {
    note_tags(env, content)
}

// A JSON number decodes to an integer when it has no fraction (`0`, `1`).
fn number(t: Term) -> NifResult<f64> {
    t.decode::<f64>().or_else(|_| t.decode::<i64>().map(|i| i as f64))
}

fn vector(t: Term) -> NifResult<Option<Vec<f64>>> {
    if t.is_atom() {
        // `nil`: no vector, similarity 0.0.
        return Ok(None);
    }
    let items: ListIterator = t.decode().map_err(|_| Error::BadArg)?;
    let mut out = Vec::with_capacity(t.list_length().unwrap_or(0));
    for item in items {
        out.push(number(item)?);
    }
    Ok(Some(out))
}

/// MMR picks: indices into the pool, in pick order. `vectors` entries are a
/// float list or `nil`. Dirty: a pool is ~200 x 1024 floats.
#[rustler::nif(schedule = "DirtyCpu")]
fn mmr_select_nif(vectors: Vec<Term>, scores: Vec<Term>, limit: usize, d: f64) -> NifResult<(Vec<usize>, usize)> {
    let base = memory::begin();
    let vectors = vectors.into_iter().map(vector).collect::<NifResult<Vec<_>>>()?;
    let scores = scores.into_iter().map(number).collect::<NifResult<Vec<_>>>()?;
    if vectors.len() != scores.len() {
        return Err(Error::BadArg);
    }
    let picked = mmr::select(vectors, &scores, limit, d);
    Ok((picked, memory::peak_since(base)))
}

fn finish<'a>(env: Env<'a>, out: Option<Vec<u8>>, base: isize) -> NifResult<(Binary<'a>, usize)> {
    let out = out.ok_or(Error::BadArg)?;
    let bin = to_binary(env, &out);
    drop(out);
    Ok((bin, memory::peak_since(base)))
}

// The three below run on the CALLING scheduler: one vector per call (1024
// float32s, or one chunk's sparse dims), tens of microseconds. Queueing them
// behind a keyword encode on prod's single dirty scheduler would cost more.

/// Numbers (floats or integers) -> packed float32 LE.
#[rustler::nif]
fn pack_f32_nif<'a>(env: Env<'a>, values: Term<'a>) -> NifResult<(Binary<'a>, usize)> {
    let base = memory::begin();
    let floats = vector(values)?.ok_or(Error::BadArg)?;
    let out = vectors::pack_f32(&floats);
    drop(floats);
    finish(env, out, base)
}

/// Packed float32 LE -> JSON array text.
#[rustler::nif]
fn dense_json_nif<'a>(env: Env<'a>, packed: Binary<'a>) -> NifResult<(Binary<'a>, usize)> {
    let base = memory::begin();
    finish(env, vectors::dense_json(packed.as_slice()), base)
}

/// Packed sparse -> `{"indices":[..],"values":[..]}` text.
#[rustler::nif]
fn sparse_json_nif<'a>(env: Env<'a>, indices: Binary<'a>, values: Binary<'a>) -> NifResult<(Binary<'a>, usize)> {
    let base = memory::begin();
    finish(env, vectors::sparse_json(indices.as_slice(), values.as_slice()), base)
}

/// Lowercase hex HMAC-SHA256 of `prefix <> text` for each text, one key
/// setup for the whole batch. Matches `Crypto.hmac_content_hash/2`.
fn hmac_hex_many<'a>(env: Env<'a>, key: Binary<'a>, prefix: Binary<'a>, texts: Vec<Binary<'a>>) -> NifResult<(Vec<Binary<'a>>, usize)> {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let base = memory::begin();
    let keyed = Hmac::<Sha256>::new_from_slice(key.as_slice()).map_err(|_| Error::BadArg)?;
    let out = texts
        .iter()
        .map(|t| {
            let mut mac = keyed.clone();
            mac.update(prefix.as_slice());
            mac.update(t.as_slice());
            let digest = mac.finalize().into_bytes();
            let mut hex = NewBinary::new(env, 64);
            for (i, b) in digest.iter().enumerate() {
                hex.as_mut_slice()[2 * i] = HEX[(b >> 4) as usize];
                hex.as_mut_slice()[2 * i + 1] = HEX[(b & 15) as usize];
            }
            hex.into()
        })
        .collect();
    Ok((out, memory::peak_since(base)))
}

#[rustler::nif]
fn hmac_hex_many_nif<'a>(env: Env<'a>, key: Binary<'a>, prefix: Binary<'a>, texts: Vec<Binary<'a>>) -> NifResult<(Vec<Binary<'a>>, usize)> {
    hmac_hex_many(env, key, prefix, texts)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn hmac_hex_many_dirty_nif<'a>(env: Env<'a>, key: Binary<'a>, prefix: Binary<'a>, texts: Vec<Binary<'a>>) -> NifResult<(Vec<Binary<'a>>, usize)> {
    hmac_hex_many(env, key, prefix, texts)
}

rustler::init!("Elixir.Engram.Native");
