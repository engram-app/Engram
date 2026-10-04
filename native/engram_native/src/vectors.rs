//! Vector packing and JSON text for the Qdrant upsert body, ported from
//! `Engram.Indexing` (`pack_vector`, `dense_json`, `vector_json`).

use std::fmt::Write;

/// Numbers -> packed float32 LE. None if a value is not finite as an f32.
/// The Elixir `<<x::float-32>>` packed an out-of-range value as +/-inf, and
/// `dense_json`'s binary generator then dropped it, leaving the vector one
/// dimension short; refusing is the fix.
pub fn pack_f32(values: &[f64]) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(values.len() * 4);
    for &v in values {
        let x = v as f32;
        if !x.is_finite() {
            return None;
        }
        out.extend_from_slice(&x.to_le_bytes());
    }
    Some(out)
}

/// Packed float32 LE -> JSON array text, each value as its SHORTEST f32
/// decimal. Qdrant stores dense vectors as f32, so `0.1` reads back as the
/// same f32 the embedder returned; widening to f64 first (the Elixir version)
/// printed 17 digits for it. None on a ragged binary or a non-finite value.
pub fn dense_json(packed: &[u8]) -> Option<Vec<u8>> {
    if !packed.len().is_multiple_of(4) {
        return None;
    }
    // Longest ryu f32 text is 16 bytes (e.g. "-0.000012345678", found by an
    // exhaustive sweep of every f32), + comma: sized up front so the buffer
    // never reallocates (a realloc holds old + new at once).
    let mut out = Vec::with_capacity(packed.len() / 4 * 17 + 2);
    let mut buf = ryu::Buffer::new();
    out.push(b'[');
    for (i, c) in packed.chunks_exact(4).enumerate() {
        let x = f32::from_le_bytes([c[0], c[1], c[2], c[3]]);
        if !x.is_finite() {
            return None;
        }
        if i > 0 {
            out.push(b',');
        }
        out.extend_from_slice(buf.format_finite(x).as_bytes());
    }
    out.push(b']');
    Some(out)
}

/// Packed sparse (u32 LE indices, f64 LE values) -> `{"indices":[..],"values":[..]}`.
/// None on ragged or mismatched binaries or a non-finite value.
pub fn sparse_json(indices: &[u8], values: &[u8]) -> Option<Vec<u8>> {
    if !indices.len().is_multiple_of(4)
        || !values.len().is_multiple_of(8)
        || indices.len() / 4 != values.len() / 8
    {
        return None;
    }
    let mut out = String::with_capacity(indices.len() * 3 + values.len() * 3 + 26);
    let mut buf = ryu::Buffer::new();
    out.push_str(r#"{"indices":["#);
    for (i, c) in indices.chunks_exact(4).enumerate() {
        if i > 0 {
            out.push(',');
        }
        let _ = write!(out, "{}", u32::from_le_bytes([c[0], c[1], c[2], c[3]]));
    }
    out.push_str(r#"],"values":["#);
    for (i, c) in values.chunks_exact(8).enumerate() {
        let w = f64::from_le_bytes(c.try_into().expect("chunks_exact(8)"));
        if !w.is_finite() {
            return None;
        }
        if i > 0 {
            out.push(',');
        }
        out.push_str(buf.format_finite(w));
    }
    out.push_str("]}");
    Some(out.into_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn packed(xs: &[f32]) -> Vec<u8> {
        xs.iter().flat_map(|x| x.to_le_bytes()).collect()
    }

    #[test]
    fn dense_prints_shortest_f32() {
        let json = dense_json(&packed(&[0.1, -0.5, 0.0, 1e-7])).unwrap();
        assert_eq!(String::from_utf8(json).unwrap(), "[0.1,-0.5,0.0,1e-7]");
        assert_eq!(dense_json(&[]).unwrap(), b"[]");
    }

    // The property the shortest-f32 choice rests on: Qdrant's JSON parser
    // reads the text as f64 and narrows to f32, and must land on the exact
    // f32 we packed (no double-rounding drift). Sweep a spread of bit patterns.
    #[test]
    fn dense_text_round_trips_through_f64_to_the_same_f32() {
        let mut bits: u32 = 0x9E37_79B9;
        for _ in 0..2_000_000 {
            bits = bits.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            let x = f32::from_bits(bits);
            if !x.is_finite() {
                continue;
            }
            let text = String::from_utf8(dense_json(&x.to_le_bytes()).unwrap()).unwrap();
            let back = text[1..text.len() - 1].parse::<f64>().unwrap() as f32;
            assert_eq!(back.to_bits(), x.to_bits(), "{x:e} -> {text}");
        }
    }

    #[test]
    fn dense_refuses_ragged_and_non_finite() {
        assert!(dense_json(&[0, 0, 0]).is_none());
        assert!(dense_json(&packed(&[f32::NAN])).is_none());
        assert!(dense_json(&packed(&[f32::INFINITY])).is_none());
    }

    #[test]
    fn sparse_shape_and_refusals() {
        let idx: Vec<u8> = [7u32, 4_000_000_000]
            .iter()
            .flat_map(|d| d.to_le_bytes())
            .collect();
        let val: Vec<u8> = [1.5f64, 0.1].iter().flat_map(|w| w.to_le_bytes()).collect();
        assert_eq!(
            String::from_utf8(sparse_json(&idx, &val).unwrap()).unwrap(),
            r#"{"indices":[7,4000000000],"values":[1.5,0.1]}"#
        );
        assert_eq!(
            sparse_json(&[], &[]).unwrap(),
            br#"{"indices":[],"values":[]}"#
        );
        assert!(sparse_json(&idx, &val[..8]).is_none());
        assert!(sparse_json(&idx[..3], &val).is_none());
        assert!(sparse_json(&idx[..4], &f64::NAN.to_le_bytes()).is_none());
    }

    #[test]
    fn pack_rounds_to_nearest_and_refuses_overflow() {
        assert_eq!(pack_f32(&[0.1, -2.0]).unwrap(), packed(&[0.1, -2.0]));
        assert!(pack_f32(&[1e300]).is_none());
        assert!(pack_f32(&[f64::NAN]).is_none());
    }
}
