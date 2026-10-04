//! JSON text -> Elixir terms, shaped exactly as `Jason.decode/1` returns them:
//! objects as maps with string keys (a repeated key keeps the FIRST value, as
//! Jason does), arrays as lists, integers as integers, other numbers as
//! floats, `null` as `nil`. Floats are correctly rounded (`float_roundtrip`),
//! as `:erlang.binary_to_float` is.
//!
//! Terms are built straight from the parser (a `DeserializeSeed` carrying the
//! `Env`), with no intermediate Rust tree.
//!
//! Two documented differences, neither reachable from Qdrant: integers beyond
//! i64/u64 come back as floats (Jason: bignum), and nesting past serde_json's
//! 128 levels is an error (Jason: no limit).

use rustler::{Encoder, Env, Term};
use serde::de::{DeserializeSeed, Deserializer, MapAccess, SeqAccess, Visitor};
use std::fmt;

pub fn decode<'a>(env: Env<'a>, text: &[u8]) -> Result<Term<'a>, serde_json::Error> {
    let mut de = serde_json::Deserializer::from_slice(text);
    let term = TermSeed(env).deserialize(&mut de)?;
    de.end()?;
    Ok(term)
}

#[derive(Clone, Copy)]
struct TermSeed<'a>(Env<'a>);

impl<'de, 'a> DeserializeSeed<'de> for TermSeed<'a> {
    type Value = Term<'a>;

    fn deserialize<D: Deserializer<'de>>(self, d: D) -> Result<Term<'a>, D::Error> {
        d.deserialize_any(self)
    }
}

impl<'de, 'a> Visitor<'de> for TermSeed<'a> {
    type Value = Term<'a>;

    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("any JSON value")
    }
    fn visit_unit<E>(self) -> Result<Term<'a>, E> {
        Ok(rustler::types::atom::nil().encode(self.0))
    }
    fn visit_bool<E>(self, b: bool) -> Result<Term<'a>, E> {
        Ok(b.encode(self.0))
    }
    fn visit_i64<E>(self, i: i64) -> Result<Term<'a>, E> {
        Ok(i.encode(self.0))
    }
    fn visit_u64<E>(self, u: u64) -> Result<Term<'a>, E> {
        Ok(u.encode(self.0))
    }
    fn visit_f64<E>(self, f: f64) -> Result<Term<'a>, E> {
        Ok(f.encode(self.0))
    }
    fn visit_str<E>(self, s: &str) -> Result<Term<'a>, E> {
        Ok(s.encode(self.0))
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Term<'a>, A::Error> {
        let mut items = Vec::with_capacity(seq.size_hint().unwrap_or(0));
        while let Some(t) = seq.next_element_seed(self)? {
            items.push(t);
        }
        Ok(items.encode(self.0))
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Term<'a>, A::Error> {
        let mut keys: Vec<Term<'a>> = Vec::new();
        let mut values: Vec<Term<'a>> = Vec::new();
        let mut seen: Vec<String> = Vec::new();
        while let Some(key) = map.next_key::<String>()? {
            let value = map.next_value_seed(self)?;
            // First occurrence wins. Objects here are small (payload fields),
            // so a linear scan beats hashing.
            if !seen.contains(&key) {
                keys.push(key.as_str().encode(self.0));
                values.push(value);
                seen.push(key);
            }
        }
        Ok(Term::map_from_term_arrays(self.0, &keys, &values).expect("keys de-duplicated above"))
    }
}
