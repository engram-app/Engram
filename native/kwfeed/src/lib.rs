//! `keyword_feed` row contract: op codes and the packed `terms` column.
//!
//! `terms` = repeated (u32 LE term id, u32 LE count), ascending by term id,
//! one entry per distinct id. Term ids are the per-user HMAC dims the
//! keyword encoder already makes (`engram_native` `dim`), so the reader
//! never needs the key or the text.

pub const UPSERT: i16 = 1;
pub const DELETE_POINTS: i16 = 2;
pub const DELETE_NOTE: i16 = 3;
pub const DELETE_VAULT: i16 = 4;
pub const DELETE_USER: i16 = 5;

/// (term id, count) pairs, in any order and with repeats -> packed column.
/// Repeated ids are summed (same-dim HMAC collisions count as one term).
pub fn pack(pairs: impl IntoIterator<Item = (u32, u32)>) -> Vec<u8> {
    let mut v: Vec<(u32, u32)> = pairs.into_iter().collect();
    v.sort_unstable_by_key(|p| p.0);
    let mut out = Vec::with_capacity(v.len() * 8);
    let mut last: Option<u32> = None;
    for (t, n) in v {
        if last == Some(t) {
            let at = out.len() - 4;
            let sum = u32::from_le_bytes(out[at..].try_into().unwrap()).saturating_add(n);
            out[at..].copy_from_slice(&sum.to_le_bytes());
        } else {
            out.extend_from_slice(&t.to_le_bytes());
            out.extend_from_slice(&n.to_le_bytes());
            last = Some(t);
        }
    }
    out
}

/// Packed column -> pairs. None on a ragged column.
pub fn unpack(b: &[u8]) -> Option<Vec<(u32, u32)>> {
    if !b.len().is_multiple_of(8) {
        return None;
    }
    Some(
        b.chunks_exact(8)
            .map(|c| {
                (
                    u32::from_le_bytes(c[..4].try_into().unwrap()),
                    u32::from_le_bytes(c[4..].try_into().unwrap()),
                )
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_sorted_and_sums_repeats() {
        let b = pack([(9, 1), (3, 2), (9, 4)]);
        assert_eq!(unpack(&b).unwrap(), vec![(3, 2), (9, 5)]);
        assert_eq!(unpack(&pack([])).unwrap(), vec![]);
        assert!(unpack(&b[..7]).is_none());
    }
}
