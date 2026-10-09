//! In-house NIFs. Each is a pure function over binaries, runs on a dirty CPU
//! scheduler, and returns BEAM binaries (so its OUTPUT is visible to
//! `:erlang.memory(:binary)`). See docs/context for the memory standard.
mod chunker;
mod frontmatter;
mod json;
mod links;
mod memory;
mod meta;
mod mmr;
mod names;
mod outline;
mod text_diff;
mod tokenizer;
mod vectors;
mod yaml;

// Under `cargo test` it counts over the system allocator (see memory.rs).
#[global_allocator]
static ALLOCATOR: memory::Counting = memory::Counting;

use engram_core::envelope;
use hmac::{Hmac, KeyInit, Mac};
use rustler::{
    Atom, Binary, Encoder, Env, Error, ListIterator, NewBinary, NifResult, OwnedBinary,
    ResourceArc, Term,
};
use sha2::Sha256;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};

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
fn encode(
    text: &str,
    key: &[u8],
    avgdl: f64,
    lang: Option<&str>,
    memo: &mut HashMap<String, u32>,
) -> (Vec<u8>, Vec<u8>, usize) {
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
    memory::measured(|| {
        let mut memo = HashMap::new();
        texts
            .iter()
            .map(|t| {
                let text = String::from_utf8_lossy(t.as_slice());
                let (i, v, n) = encode(&text, key.as_slice(), avgdl, lang.as_deref(), &mut memo);
                (to_binary(env, &i), to_binary(env, &v), n)
            })
            .collect()
    })
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

/// `sized_nif!(f, f_nif, f_dirty_nif, (params) [arg names] -> Ret)` exports
/// `f_nif` (calling scheduler) and `f_dirty_nif` (dirty CPU), both calling
/// `f`; `Engram.Native.sized/3` picks one by input size. Names are spelled
/// out (macro_rules cannot build an identifier). Params and the return type
/// pass as raw tokens (a `$x:ty` reaches `#[rustler::nif]` as an opaque
/// group it rejects), and `env` is written here, not passed in: rustler
/// binds it by name, so it must share the attribute's hygiene.
macro_rules! sized_nif {
    ($imp:ident, $inline:ident, $dirty:ident, <$lt:lifetime>(env, $($params:tt)*) [$($arg:ident),*] -> $($ret:tt)+) => {
        #[rustler::nif]
        fn $inline<$lt>(env: Env<$lt>, $($params)*) -> $($ret)+ {
            $imp(env, $($arg),*)
        }

        #[rustler::nif(schedule = "DirtyCpu")]
        fn $dirty<$lt>(env: Env<$lt>, $($params)*) -> $($ret)+ {
            $imp(env, $($arg),*)
        }
    };
    ($imp:ident, $inline:ident, $dirty:ident, $params:tt [$($arg:ident),*] -> $($ret:tt)+) => {
        #[rustler::nif]
        fn $inline $params -> $($ret)+ {
            $imp($($arg),*)
        }

        #[rustler::nif(schedule = "DirtyCpu")]
        fn $dirty $params -> $($ret)+ {
            $imp($($arg),*)
        }
    };
}

/// `Links.Parser.extract/2`: `{[{position, kind, target_start, target_len,
/// target, alias, anchor}], scrub_count, cut?}`, and the call's native peak.
/// Each link is encoded as a term the moment it is built, so the output
/// never exists as a Rust copy. Linear in the note. `limit` keeps the first
/// N links (usize::MAX: all, for the rename rewrite, which needs every one);
/// `cut?` says the limit dropped some.
fn link_extract<'a>(
    env: Env<'a>,
    content: &str,
    limit: usize,
) -> ((Vec<Term<'a>>, usize, bool), usize) {
    memory::measured(|| {
        let mut terms = Vec::new();
        let (scrubs, cut) = links::extract(
            content,
            limit,
            |(pos, kind, ts, tl, target, alias, anchor)| {
                terms.push(
                    (pos, kind, ts, tl, target.as_ref(), alias, anchor.as_deref()).encode(env),
                );
            },
        );
        (terms, scrubs, cut)
    })
}

sized_nif!(link_extract, link_extract_nif, link_extract_dirty_nif, <'a>(env, content: &str, limit: usize) [content, limit] -> ((Vec<Term<'a>>, usize, bool), usize));

/// `Helpers.extract_title/2` without the file-name fallback, and the peak.
fn note_title(content: &str) -> (Option<String>, usize) {
    memory::measured(|| meta::title(content))
}

sized_nif!(note_title, note_title_nif, note_title_dirty_nif, (content: &str) [content] -> (Option<String>, usize));

/// `Helpers.extract_title_and_tags/2` without the file-name fallback, and
/// the peak.
fn note_meta<'a>(env: Env<'a>, content: &str) -> ((Option<String>, Vec<Term<'a>>), usize) {
    memory::measured(|| {
        let mut tags = Vec::new();
        let title = meta::title_and_tags(content, |t| tags.push(t.encode(env)));
        (title, tags)
    })
}

sized_nif!(note_meta, note_meta_nif, note_meta_dirty_nif, <'a>(env, content: &str) [content] -> ((Option<String>, Vec<Term<'a>>), usize));

// A JSON number decodes to an integer when it has no fraction (`0`, `1`).
fn number(t: Term) -> NifResult<f64> {
    t.decode::<f64>()
        .or_else(|_| t.decode::<i64>().map(|i| i as f64))
}

fn vector(t: Term) -> NifResult<Option<Vec<f64>>> {
    // `nil` only: no vector, similarity 0.0. Any other atom is refused, as
    // the Elixir version's `unit/1` refused it.
    if t.is_atom() {
        return match t.decode::<rustler::Atom>() {
            Ok(a) if a == rustler::types::atom::nil() => Ok(None),
            _ => Err(Error::BadArg),
        };
    }
    // `list_length` fails on an improper list (`[1.0 | 2.0]`), which the
    // iterator alone would silently truncate.
    let len = t.list_length().map_err(|_| Error::BadArg)?;
    let items: ListIterator = t.decode().map_err(|_| Error::BadArg)?;
    let mut out = Vec::with_capacity(len);
    for item in items {
        out.push(number(item)?);
    }
    Ok(Some(out))
}

/// MMR picks: indices into the pool, in pick order. `vectors` entries are a
/// float list or `nil`. Dirty: a pool is ~200 x 1024 floats.
#[rustler::nif(schedule = "DirtyCpu")]
fn mmr_select_nif(
    vectors: Vec<Term>,
    scores: Vec<Term>,
    limit: usize,
    d: f64,
) -> NifResult<(Vec<usize>, usize)> {
    let (picked, peak) = memory::measured(|| {
        let vectors = vectors
            .into_iter()
            .map(vector)
            .collect::<NifResult<Vec<_>>>()?;
        let scores = scores
            .into_iter()
            .map(number)
            .collect::<NifResult<Vec<_>>>()?;
        if vectors.len() != scores.len() {
            return Err(Error::BadArg);
        }
        Ok(mmr::select(vectors, &scores, limit, d))
    });
    Ok((picked?, peak))
}

/// A measured `Option<Vec<u8>>` (None = bad input) as a binary and the peak.
fn finish<'a>(
    env: Env<'a>,
    (out, peak): (NifResult<Option<Vec<u8>>>, usize),
) -> NifResult<(Binary<'a>, usize)> {
    Ok((to_binary(env, &out?.ok_or(Error::BadArg)?), peak))
}

// The three below run on the CALLING scheduler: one vector per call (1024
// float32s, or one chunk's sparse dims), tens of microseconds. Queueing them
// behind a keyword encode on prod's single dirty scheduler would cost more.

/// Numbers (floats or integers) -> packed float32 LE.
#[rustler::nif]
fn pack_f32_nif<'a>(env: Env<'a>, values: Term<'a>) -> NifResult<(Binary<'a>, usize)> {
    finish(
        env,
        memory::measured(|| Ok(vectors::pack_f32(&vector(values)?.ok_or(Error::BadArg)?))),
    )
}

/// Packed float32 LE -> JSON array text.
#[rustler::nif]
fn dense_json_nif<'a>(env: Env<'a>, packed: Binary<'a>) -> NifResult<(Binary<'a>, usize)> {
    finish(
        env,
        memory::measured(|| Ok(vectors::dense_json(packed.as_slice()))),
    )
}

/// Packed sparse -> `{"indices":[..],"values":[..]}` text.
#[rustler::nif]
fn sparse_json_nif<'a>(
    env: Env<'a>,
    indices: Binary<'a>,
    values: Binary<'a>,
) -> NifResult<(Binary<'a>, usize)> {
    finish(
        env,
        memory::measured(|| Ok(vectors::sparse_json(indices.as_slice(), values.as_slice()))),
    )
}

/// Lowercase hex HMAC-SHA256 of `prefix <> text` for each text, one key
/// setup for the whole batch. Matches `Crypto.hmac_content_hash/2`.
fn hmac_hex_many<'a>(
    env: Env<'a>,
    key: Binary<'a>,
    prefix: Binary<'a>,
    texts: Vec<Binary<'a>>,
) -> NifResult<(Vec<Binary<'a>>, usize)> {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let (out, peak) = memory::measured(|| -> NifResult<Vec<Binary<'a>>> {
        let keyed = Hmac::<Sha256>::new_from_slice(key.as_slice()).map_err(|_| Error::BadArg)?;
        Ok(texts
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
            .collect())
    });
    Ok((out?, peak))
}

sized_nif!(hmac_hex_many, hmac_hex_many_nif, hmac_hex_many_dirty_nif, <'a>(env, key: Binary<'a>, prefix: Binary<'a>, texts: Vec<Binary<'a>>) [key, prefix, texts] -> NifResult<(Vec<Binary<'a>>, usize)>);

fn json_decode<'a>(env: Env<'a>, text: Binary<'a>) -> NifResult<(Term<'a>, usize)> {
    let (term, peak) = memory::measured(|| json::decode(env, text.as_slice()));
    Ok((term.map_err(|_| Error::BadArg)?, peak))
}

sized_nif!(json_decode, json_decode_nif, json_decode_dirty_nif, <'a>(env, text: Binary<'a>) [text] -> NifResult<(Term<'a>, usize)>);

/// `Engram.Parsers.Markdown.parse/2`'s chunks (positions are assigned in
/// Elixir), and the call's native peak.
fn chunk<'a>(env: Env<'a>, content: &str, folder: &str, title: &str) -> (Vec<Term<'a>>, usize) {
    memory::measured(|| {
        let mut out = Vec::new();
        chunker::each_chunk(content, folder, title, |c| out.push(c.encode(env)));
        out
    })
}

sized_nif!(chunk, chunk_nif, chunk_dirty_nif, <'a>(env, content: &str, folder: &str, title: &str) [content, folder, title] -> (Vec<Term<'a>>, usize));

/// `Frontmatter.split/1` as offsets: nil, or {block_start, block_end,
/// body_start, add_newline}, with the native peak. Takes raw bytes: invalid
/// UTF-8 splits as the Elixir regexes did.
fn frontmatter_split(content: Binary) -> (frontmatter::Split, usize) {
    memory::measured(|| frontmatter::split(content.as_slice()))
}

sized_nif!(frontmatter_split, frontmatter_split_nif, frontmatter_split_dirty_nif, (content: Binary) [content] -> (frontmatter::Split, usize));

/// `Frontmatter.parse/1`'s common case: `[{key, json}]` in source order, or
/// nil (YamlElixir decides), with the native peak.
fn frontmatter_parse(block: &str) -> (Option<Vec<(String, String)>>, usize) {
    memory::measured(|| yaml::parse(block))
}

sized_nif!(frontmatter_parse, frontmatter_parse_nif, frontmatter_parse_dirty_nif, (block: &str) [block] -> (Option<Vec<(String, String)>>, usize));

/// `CrdtBridge.diff_into_text/2`'s span, and the peak (zero: no allocation).
fn text_diff(current: &str, incoming: &str) -> ((usize, usize, usize, usize), usize) {
    memory::measured(|| text_diff::diff(current, incoming))
}

sized_nif!(text_diff, text_diff_nif, text_diff_dirty_nif, (current: &str, incoming: &str) [current, incoming] -> ((usize, usize, usize, usize), usize));

/// `Rewriter.apply_edits!/3`'s UTF-16 offsets: one per byte offset (sorted,
/// each on a char boundary), in one pass, and the peak. Raises otherwise.
fn utf16_offsets(text: &str, at: Vec<usize>) -> NifResult<(Vec<usize>, usize)> {
    let (out, peak) = memory::measured(|| text_diff::utf16_offsets(text, &at));
    Ok((out.ok_or(Error::BadArg)?, peak))
}

sized_nif!(utf16_offsets, utf16_offsets_nif, utf16_offsets_dirty_nif, (text: &str, at: Vec<usize>) [text, at] -> NifResult<(Vec<usize>, usize)>);

/// `Engram.MCP.Sections`' view of a note, from the note as stored:
/// `{headings, explained_lines, safe_ranges}` (see outline.rs), or nil when
/// it has more than `outline::MAX_ITEMS` of them; and the peak. Raises on a
/// sourcepos outside the text, as the Elixir version did. Always dirty:
/// comrak takes ~10 ms on 16 KB of dense markup (a tight list, `# h` lines),
/// far past what may run on a normal scheduler, and MCP calls do not feel
/// the hop.
#[rustler::nif(schedule = "DirtyCpu")]
fn md_outline_nif(content: &str) -> NifResult<(Option<outline::Outline>, usize)> {
    let (o, peak) = memory::measured(|| outline::outline(content));
    match o {
        Ok(o) => Ok((Some(o), peak)),
        Err(outline::Refused::TooComplex) => Ok((None, peak)),
        Err(outline::Refused::BadSourcepos) => Err(Error::BadArg),
    }
}

rustler::atoms! { none, zstd, auto, reschedule }

fn envelope_mode(mode: Atom) -> NifResult<envelope::Mode> {
    match mode {
        m if m == none() => Ok(envelope::Mode::None),
        m if m == zstd() => Ok(envelope::Mode::Zstd),
        m if m == auto() => Ok(envelope::Mode::Auto),
        _ => Err(Error::BadArg),
    }
}

/// `{ct_with_tag, nonce_field}`, or `:error` (bad key, no entropy). The
/// ciphertext was sealed straight into its BEAM binary.
fn sealed<'a>(env: Env<'a>, out: Result<(OwnedBinary, Vec<u8>), envelope::Error>) -> Term<'a> {
    match out {
        Ok((ct, nonce)) => (ct.release(env), to_binary(env, &nonce)).encode(env),
        Err(envelope::Error) => rustler::types::atom::error().encode(env),
    }
}

/// Every envelope seal (calls, input bytes at 0, 1) and open (2, 3) since
/// the library loaded, inline or dirty. `Engram.Native` skips the per-call
/// telemetry event for inline format-0 seals and every inline open, so this
/// is their only count. An open the inline NIF hands back as `:reschedule`
/// is counted once, by the dirty call that finishes it.
/// Relaxed: counters, not synchronisation.
static ENVELOPE_COUNTS: [AtomicU64; 4] = [const { AtomicU64::new(0) }; 4];

fn count_envelope(i: usize, bytes: usize) {
    ENVELOPE_COUNTS[i].fetch_add(1, Relaxed);
    ENVELOPE_COUNTS[i + 1].fetch_add(bytes as u64, Relaxed);
}

/// `{seal_calls, seal_bytes, open_calls, open_bytes}`.
#[rustler::nif]
fn envelope_counts_nif() -> (u64, u64, u64, u64) {
    let [a, b, c, d] = &ENVELOPE_COUNTS;
    (
        a.load(Relaxed),
        b.load(Relaxed),
        c.load(Relaxed),
        d.load(Relaxed),
    )
}

/// `Engram.Crypto.Envelope.encrypt/3`'s engine: optional zstd + AES-256-GCM
/// (see native/engram_core/src/envelope.rs for the formats), and the peak.
fn envelope_seal<'a>(
    env: Env<'a>,
    plain: Binary<'a>,
    key: Binary<'a>,
    aad: Binary<'a>,
    mode: Atom,
) -> NifResult<(Term<'a>, usize)> {
    let mode = envelope_mode(mode)?;
    count_envelope(0, plain.len());
    // The nonce comes from the OS here, at the edge: the core has no RNG.
    let (out, peak) = memory::measured(|| {
        let mut nonce = [0u8; envelope::NONCE];
        getrandom::fill(&mut nonce).map_err(|_| envelope::Error)?;
        envelope::seal(&plain, &key, &aad, mode, nonce, OwnedBinary::new)
    });
    Ok((sealed(env, out), peak))
}

sized_nif!(envelope_seal, envelope_seal_nif, envelope_seal_dirty_nif, <'a>(env, plain: Binary<'a>, key: Binary<'a>, aad: Binary<'a>, mode: Atom) [plain, key, aad, mode] -> NifResult<(Term<'a>, usize)>);

/// Test hook: a seal with a caller-chosen nonce, for byte-for-byte parity
/// with `:crypto`. A repeated nonce under one key breaks AES-GCM, so it is
/// compiled only with the `test-hooks` feature (dev and test configs): the
/// release NIF does not export it.
#[cfg(feature = "test-hooks")]
#[rustler::nif]
fn envelope_seal_with_nonce_nif<'a>(
    env: Env<'a>,
    plain: Binary<'a>,
    key: Binary<'a>,
    aad: Binary<'a>,
    mode: Atom,
    nonce: Binary<'a>,
) -> NifResult<(Term<'a>, usize)> {
    let mode = envelope_mode(mode)?;
    let nonce: [u8; envelope::NONCE] = nonce.as_slice().try_into().map_err(|_| Error::BadArg)?;
    let (out, peak) =
        memory::measured(|| envelope::seal(&plain, &key, &aad, mode, nonce, OwnedBinary::new));
    Ok((sealed(env, out), peak))
}

/// `Engram.Crypto.Envelope.decrypt/4`'s engine: any format; `:error` on
/// anything that does not authenticate and decode. Never raises on input.
/// `inflate_max` is the core's budget for a zstd body (see the pair below).
fn envelope_open<'a>(
    env: Env<'a>,
    ct: Binary<'a>,
    nonce: Binary<'a>,
    key: Binary<'a>,
    aad: Binary<'a>,
    inflate_max: usize,
) -> (Term<'a>, usize) {
    let (out, peak) =
        memory::measured(|| envelope::open(&ct, &nonce, &key, &aad, inflate_max, OwnedBinary::new));
    if !matches!(out, Ok(envelope::Opened::OverBudget)) {
        count_envelope(2, ct.len());
    }
    // Format 0 and raw format 1 decrypt in their BEAM binary; raw skips the
    // codec byte as a sub-binary, not a copy.
    let error = || rustler::types::atom::error().encode(env);
    let term = match out {
        Ok(envelope::Opened::InPlace(buf, 0)) => buf.release(env).encode(env),
        Ok(envelope::Opened::InPlace(buf, skip)) => {
            let buf = buf.release(env);
            match buf.make_subbinary(skip, buf.len() - skip) {
                Ok(sub) => sub.encode(env),
                Err(_) => error(),
            }
        }
        Ok(envelope::Opened::Inflated(v)) => to_binary(env, &v).encode(env),
        Ok(envelope::Opened::OverBudget) => reschedule().encode(env),
        Err(envelope::Error) => error(),
    };
    (term, peak)
}

/// `Engram.Native`'s @inline_max: the most a zstd body may inflate to on the
/// calling scheduler.
const INLINE_INFLATE_MAX: usize = 16_384;

// The open pair is written out, not `sized_nif!`: the two differ in budget.
// Inline (the caller keeps the ciphertext to 16 KB): decrypts, and inflates
// a zstd body only if its frame declares at most INLINE_INFLATE_MAX bytes,
// else returns `:reschedule` for the dirty variant (decode work is not
// bounded by ciphertext size: 1.5 KB of zstd inflated to 50 MB). The budget
// lives here, not in the caller, so no argument can lift it.

#[rustler::nif]
fn envelope_open_nif<'a>(
    env: Env<'a>,
    ct: Binary<'a>,
    nonce: Binary<'a>,
    key: Binary<'a>,
    aad: Binary<'a>,
) -> (Term<'a>, usize) {
    envelope_open(env, ct, nonce, key, aad, INLINE_INFLATE_MAX)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn envelope_open_dirty_nif<'a>(
    env: Env<'a>,
    ct: Binary<'a>,
    nonce: Binary<'a>,
    key: Binary<'a>,
    aad: Binary<'a>,
) -> (Term<'a>, usize) {
    envelope_open(env, ct, nonce, key, aad, usize::MAX)
}

// One encrypted field per row: raw 16-byte id, whether its AAD binds the id
// (`dek_version >= 2`), ciphertext, nonce field.
type FieldRow<'a> = (Binary<'a>, bool, Binary<'a>, Binary<'a>);

/// Batch `envelope_open` for one column across many rows under one key: the
/// key schedule is built once, and the AAD (`prefix <> raw id`, or empty for
/// legacy rows) is assembled here instead of per row in Elixir. `None` if
/// any row fails, matching the per-row path, which raises.
fn envelope_open_many<'a>(
    env: Env<'a>,
    key: Binary<'a>,
    prefix: Binary<'a>,
    rows: Vec<FieldRow<'a>>,
) -> (Option<Vec<Binary<'a>>>, usize) {
    let n = rows.len() as u64;
    let (out, peak) = memory::measured(|| {
        let k = envelope::OpenKey::new(&key).ok()?;
        let mut aad = Vec::with_capacity(prefix.len() + 16);
        rows.iter()
            .map(|(id, bind, ct, nonce)| {
                aad.clear();
                if *bind {
                    aad.extend_from_slice(&prefix);
                    aad.extend_from_slice(id);
                }
                match k.open(ct, nonce, &aad, usize::MAX, OwnedBinary::new).ok()? {
                    envelope::Opened::InPlace(buf, skip) => {
                        let buf = buf.release(env);
                        buf.make_subbinary(skip, buf.len() - skip).ok()
                    }
                    envelope::Opened::Inflated(v) => {
                        let mut b = NewBinary::new(env, v.len());
                        b.as_mut_slice().copy_from_slice(&v);
                        Some(b.into())
                    }
                    envelope::Opened::OverBudget => None,
                }
            })
            .collect::<Option<Vec<_>>>()
    });
    ENVELOPE_COUNTS[2].fetch_add(n, Relaxed);
    (out, peak)
}

sized_nif!(envelope_open_many, envelope_open_many_nif, envelope_open_many_dirty_nif, <'a>(env, key: Binary<'a>, prefix: Binary<'a>, rows: Vec<FieldRow<'a>>) [key, prefix, rows] -> (Option<Vec<Binary<'a>>>, usize));

#[rustler::resource_impl]
impl rustler::Resource for names::NameIndex {}

// A row for the name index: the path field plus an optional title field.
type NameRow<'a> = (
    Binary<'a>,
    bool,
    Binary<'a>,
    Binary<'a>,
    Option<Binary<'a>>,
    Option<Binary<'a>>,
);

/// Builds a vault's name index; `{handle, approx_bytes}` or nil. Always
/// dirty: it decrypts the whole vault's names.
#[rustler::nif(schedule = "DirtyCpu")]
fn name_index_build_nif<'a>(
    key: Binary<'a>,
    path_prefix: Binary<'a>,
    title_prefix: Binary<'a>,
    rows: Vec<NameRow<'a>>,
) -> (Option<(ResourceArc<names::NameIndex>, usize)>, usize) {
    let (out, peak) = memory::measured(|| {
        let rows: Vec<names::Row> = rows
            .iter()
            .map(|(id, bind, pc, pn, tc, tn)| names::Row {
                id,
                bind: *bind,
                path: (pc, pn),
                title: match (tc, tn) {
                    (Some(c), Some(n)) => Some((c.as_slice(), n.as_slice())),
                    _ => None,
                },
            })
            .collect();
        names::NameIndex::build(&key, &path_prefix, &title_prefix, &rows).map(|i| {
            let bytes = i.bytes();
            (ResourceArc::new(i), bytes)
        })
    });
    (out, peak)
}

/// `{paths, total, peak}`. Dirty: a fuzzy pass over a large vault takes
/// milliseconds.
#[rustler::nif(schedule = "DirtyCpu")]
fn name_index_search_nif(
    index: ResourceArc<names::NameIndex>,
    query: &str,
    limit: usize,
) -> (Vec<String>, usize, usize) {
    let ((hits, total), peak) = memory::measured(|| index.search(query, limit));
    (hits, total, peak)
}

// Patches take the write lock, which waits out any running search. Dirty, so
// that wait never parks a normal scheduler (prod runs exactly one).
#[rustler::nif(schedule = "DirtyCpu")]
fn name_index_put_nif(
    index: ResourceArc<names::NameIndex>,
    id: Binary,
    path: &str,
    title: &str,
) -> bool {
    index.put(&id, path, title)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn name_index_delete_nif(index: ResourceArc<names::NameIndex>, id: Binary, path: &str) -> Atom {
    index.delete(&id, path);
    rustler::types::atom::ok()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn name_index_bytes_nif(index: ResourceArc<names::NameIndex>) -> usize {
    index.bytes()
}

rustler::init!("Elixir.Engram.Native");
