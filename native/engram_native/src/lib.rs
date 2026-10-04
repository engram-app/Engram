//! In-house NIFs. Each is a pure function over binaries, runs on a dirty CPU
//! scheduler, and returns BEAM binaries (so its OUTPUT is visible to
//! `:erlang.memory(:binary)`). See docs/context for the memory standard.
mod memory;
mod snowball;
mod tokenizer;

// Not under `cargo test`: enif_alloc only exists inside a running BEAM.
#[cfg(not(test))]
#[global_allocator]
static ALLOCATOR: memory::Counting = memory::Counting;

use hmac::{Hmac, Mac};
use rustler::{Binary, Env, NewBinary};
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

/// Live bytes held by this library's Rust heap, process-wide.
#[rustler::nif]
fn live_bytes() -> isize {
    memory::live_bytes()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tokens_with_len(text: &str, lang: Option<String>) -> (Vec<String>, usize) {
    tokenizer::tokens_with_len(text, lang.as_deref())
}

rustler::init!("Elixir.Engram.Native");
