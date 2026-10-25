//! Rival-lineage detector over a Yjs v1 update (read-only audit).
//!
//! A ROOT insert is an item with neither an origin nor a right origin: it was
//! inserted into an EMPTY sequence. Yjs keeps deleted neighbours as origins,
//! so clearing a note and retyping it does not mint a new root; only a client
//! that wrote into a doc it had never synced does. Two root lineages in the
//! same body text is a writer that seeded a doc it had never synced, which
//! Yjs unions into a doubled body (the fresh-device seed, #846, #476).
//!
//! yrs keeps `Item.origin` crate-private, so this walks the update's struct
//! section with yrs's public decoder, the same steps as `Update::decode`.
//!
//! Input MUST be yrs's own fresh re-encode of the server's stored state
//! (`encode_state_as_update`), never client bytes, for two reasons:
//!
//! * yrs's `IdRange` and `Any` decoders allocate from varint lengths read
//!   off the wire; a crafted length is an allocation failure, and that
//!   aborts the whole BEAM (`catch_unwind` cannot stop it).
//! * a raise would carry the input, a plaintext note body, into the error
//!   report.

use std::ops::Range;

use yrs::block::{
    ItemContent, BLOCK_GC_REF_NUMBER, BLOCK_SKIP_REF_NUMBER, HAS_ORIGIN, HAS_PARENT_SUB,
    HAS_RIGHT_ORIGIN,
};
use yrs::encoding::read::{Cursor, Error, Read};
use yrs::updates::decoder::{Decode, Decoder, DecoderV1};
use yrs::{DeleteSet, OffsetKind};

/// A root struct plus the same-client structs that continue it clock by clock
/// (origin = the previous clock, no right origin): the pieces yrs split it
/// into on a partial delete, and the client's own appends.
struct Lineage {
    client: u64,
    clocks: Range<u32>,
}

/// `(client, live_utf16_len, total_utf16_len)` of one root lineage.
pub type RootLineage = (u64, u32, u32);

/// A [`RootLineage`] for EVERY root insert into the
/// root-level type named `root` (map entries excluded), wholly deleted ones
/// included. One entry per root struct, so two entries from one client are two
/// lineages. Live alone cannot tell "rival deleted, original live" from
/// "original deleted, rival live" (a cleared note a fresh device re-seeded):
/// both leave one live lineage, so the caller needs the dead ones too.
pub fn root_inserts(update: &[u8], root: &str) -> Result<Vec<RootLineage>, Error> {
    let mut d = DecoderV1::new(Cursor::new(update));
    let clients: u32 = d.read_var()?;
    let mut lineages: Vec<Lineage> = Vec::new();
    for _ in 0..clients {
        let structs: u32 = d.read_var()?;
        let client = d.read_client()?;
        let mut clock: u32 = d.read_var()?;
        // Whether the previous struct of this client belongs to the last lineage.
        let mut extends = false;
        for _ in 0..structs {
            match d.read_info()? {
                BLOCK_SKIP_REF_NUMBER => {
                    let len: u32 = d.read_var()?;
                    clock += len;
                    extends = false;
                }
                BLOCK_GC_REF_NUMBER => {
                    clock += d.read_len()?;
                    extends = false;
                }
                info => {
                    let has_origin = info & HAS_ORIGIN != 0;
                    let has_right = info & HAS_RIGHT_ORIGIN != 0;
                    let origin = if has_origin {
                        Some(d.read_left_id()?)
                    } else {
                        None
                    };
                    if has_right {
                        d.read_right_id()?;
                    }
                    let mut is_root = false;
                    if !has_origin && !has_right {
                        is_root = if d.read_parent_info()? {
                            d.read_string()? == root
                        } else {
                            d.read_left_id()?; // nested type: never the body
                            false
                        };
                        if info & HAS_PARENT_SUB != 0 {
                            d.read_string()?;
                            is_root = false; // a map entry, not a sequence insert
                        }
                    }
                    let len = ItemContent::decode(&mut d, info)?.len(OffsetKind::Utf16);
                    let continues = extends
                        && !has_right
                        && origin.is_some_and(|o| o.client == client && o.clock + 1 == clock);
                    if is_root {
                        lineages.push(Lineage {
                            client,
                            clocks: clock..clock + len,
                        });
                        extends = true;
                    } else if continues {
                        if let Some(l) = lineages.last_mut() {
                            l.clocks.end = clock + len;
                        }
                    } else {
                        extends = false;
                    }
                    clock += len;
                }
            }
        }
    }
    // The trailing delete set. A root GC'd to `ItemContent::Deleted` is in it
    // too, so this one check covers both.
    let deleted = DeleteSet::decode(&mut d)?;
    Ok(lineages
        .into_iter()
        .map(|l| {
            let total = l.clocks.end - l.clocks.start;
            let gone = deleted
                .range(&l.client)
                .map_or(0, |r| covered(r.iter(), &l.clocks));
            (l.client, total.saturating_sub(gone), total)
        })
        .collect())
}

/// Clock units of `span` covered by `ranges` (may overlap or be unsorted).
fn covered<'a>(ranges: impl Iterator<Item = &'a Range<u32>>, span: &Range<u32>) -> u32 {
    let mut parts: Vec<Range<u32>> = ranges
        .map(|r| r.start.max(span.start)..r.end.min(span.end))
        .filter(|r| r.start < r.end)
        .collect();
    parts.sort_by_key(|r| r.start);
    let (mut total, mut reached) = (0, span.start);
    for r in parts {
        let from = r.start.max(reached);
        if r.end > from {
            total += r.end - from;
            reached = r.end;
        }
    }
    total
}

#[cfg(test)]
mod tests {
    use super::{root_inserts, RootLineage};
    use yrs::updates::decoder::Decode;
    use yrs::{Doc, GetString, Map, ReadTxn, StateVector, Text, Transact, Update};

    fn state(doc: &Doc) -> Vec<u8> {
        doc.transact()
            .encode_state_as_update_v1(&StateVector::default())
    }

    /// Sorted `(client, live, total)`.
    fn roots(doc: &Doc) -> Vec<RootLineage> {
        let mut r = root_inserts(&state(doc), "content").unwrap();
        r.sort();
        r
    }

    fn seeded(client: u64, text: &str) -> Doc {
        let doc = Doc::with_client_id(client);
        doc.get_or_insert_text("content")
            .insert(&mut doc.transact_mut(), 0, text);
        doc
    }

    fn apply(doc: &Doc, update: &[u8]) {
        doc.transact_mut()
            .apply_update(Update::decode_v1(update).unwrap())
            .unwrap();
    }

    fn body(doc: &Doc) -> String {
        doc.get_or_insert_text("content")
            .get_string(&doc.transact())
    }

    /// Client 1 wrote "old text"; client 2 synced it, cleared it and typed
    /// "new text".
    fn cleared_and_retyped() -> Doc {
        let a = seeded(1, "old text");
        let b = Doc::with_client_id(2);
        apply(&b, &state(&a));
        let t = b.get_or_insert_text("content");
        t.remove_range(&mut b.transact_mut(), 0, 8);
        t.insert(&mut b.transact_mut(), 0, "new text");
        b
    }

    #[test]
    fn one_lineage_with_edits_is_one_root() {
        let a = seeded(1, "first body line.\n");
        let b = Doc::with_client_id(2);
        apply(&b, &state(&a));
        let t = b.get_or_insert_text("content");
        t.insert(&mut b.transact_mut(), 17, "second line.\n");
        t.insert(&mut b.transact_mut(), 0, "# title\n");
        assert_eq!(roots(&b), vec![(1, 17, 17)]);
    }

    #[test]
    fn a_plain_doubled_note_has_two_live_roots() {
        // RIVAL: a fresh client seeded an existing note.
        let a = seeded(1, "first body line.\n");
        apply(&a, &state(&seeded(2, "first body line.\nsecond line.\n")));
        assert_eq!(body(&a).matches("first body line.").count(), 2);
        assert_eq!(roots(&a), vec![(1, 17, 17), (2, 30, 30)]);
    }

    #[test]
    fn clearing_and_retyping_mints_no_new_root() {
        // HEALTHY: retyping hangs off client 1's deleted structs, so client 2
        // is not a root. One lineage, wholly deleted.
        assert_eq!(roots(&cleared_and_retyped()), vec![(1, 0, 8)]);
    }

    #[test]
    fn a_fresh_seed_over_a_cleared_note_keeps_the_dead_root() {
        // SUSPECT: one LIVE root only, yet the body is doubled. Live roots
        // alone call this healthy (the I1 false negative); the dead root
        // beside a live one is what flags it.
        let b = cleared_and_retyped();
        apply(&b, &state(&seeded(3, "new text")));
        assert_eq!(body(&b), "new textnew text");
        assert_eq!(roots(&b), vec![(1, 0, 8), (3, 8, 8)]);
    }

    #[test]
    fn map_entries_and_other_roots_are_ignored() {
        let a = seeded(1, "body");
        let fm = a.get_or_insert_map("frontmatter");
        fm.insert(&mut a.transact_mut(), "tags", "x");
        let other = Doc::with_client_id(3);
        other
            .get_or_insert_text("other")
            .insert(&mut other.transact_mut(), 0, "y");
        apply(&a, &state(&other));
        assert_eq!(roots(&a), vec![(1, 4, 4)]);
    }

    /// The doubled doc and the offset of client 2's rival copy (30 units).
    fn doubled() -> (Doc, u32) {
        let a = seeded(1, "first body line.\n");
        apply(&a, &state(&seeded(2, "first body line.\nsecond line.\n")));
        let at = if body(&a).starts_with("first body line.\nsecond") {
            0
        } else {
            17
        };
        (a, at)
    }

    fn remove(a: &Doc, at: u32, len: u32) {
        let t = a.get_or_insert_text("content");
        t.remove_range(&mut a.transact_mut(), at, len);
    }

    #[test]
    fn a_deleted_rival_copy_is_a_dead_root() {
        // SUSPECT, not healthy: the user removed the duplicate by hand, which
        // leaves the same shape (one live root, one dead) as a fresh seed over
        // a cleared note. Only the text tells them apart, so triage reads it.
        let (a, at) = doubled();
        remove(&a, at, 30);
        assert_eq!(roots(&a), vec![(1, 17, 17), (2, 0, 30)]);
    }

    #[test]
    fn a_rival_with_only_its_head_deleted_is_still_live() {
        // Splits the rival's root struct: the root piece is fully deleted,
        // its live continuation carries an origin.
        let (a, at) = doubled();
        remove(&a, at, 6);
        assert_eq!(roots(&a), vec![(1, 17, 17), (2, 24, 30)]);
    }

    #[test]
    fn a_partly_deleted_rival_reports_its_live_length() {
        let (a, at) = doubled();
        remove(&a, at + 10, 20);
        assert_eq!(roots(&a), vec![(1, 17, 17), (2, 10, 30)]);
    }

    #[test]
    fn empty_and_malformed_updates() {
        assert_eq!(roots(&Doc::new()), Vec::<RootLineage>::new());
        assert!(root_inserts(&[0xff, 0xff, 0xff], "content").is_err());
    }
}
