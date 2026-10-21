//! Rival-lineage detector over a Yjs v1 update (read-only audit).
//!
//! A ROOT insert is an item with neither an origin nor a right origin: it was
//! inserted into an EMPTY sequence. Yjs keeps deleted neighbours as origins,
//! so clearing a note and retyping it does not mint a new root; only a client
//! that wrote into a doc it had never synced does. Two clients owning root
//! inserts in the same body text is two lineages, which Yjs unions into a
//! doubled body (the fresh-device seed, #846, #476).
//!
//! yrs keeps `Item.origin` crate-private, so this walks the update's struct
//! section with yrs's public decoder, the same steps as `Update::decode`.
//! Input is the server's own stored state, not client bytes.

use yrs::block::{
    ItemContent, BLOCK_GC_REF_NUMBER, BLOCK_SKIP_REF_NUMBER, HAS_ORIGIN, HAS_PARENT_SUB,
    HAS_RIGHT_ORIGIN,
};
use yrs::encoding::read::{Cursor, Error, Read};
use yrs::updates::decoder::{Decoder, DecoderV1};
use yrs::OffsetKind;

/// `(client, utf16_len)` for every root insert into the root-level type named
/// `root` (map entries excluded). One entry per stored struct: a client's
/// root insert merged with its own later appends reports the merged length.
pub fn root_inserts(update: &[u8], root: &str) -> Result<Vec<(u64, u32)>, Error> {
    let mut d = DecoderV1::new(Cursor::new(update));
    let clients: u32 = d.read_var()?;
    let mut out = Vec::new();
    for _ in 0..clients {
        let structs: u32 = d.read_var()?;
        let client = d.read_client()?;
        let _clock: u32 = d.read_var()?;
        for _ in 0..structs {
            match d.read_info()? {
                BLOCK_SKIP_REF_NUMBER => {
                    let _len: u32 = d.read_var()?;
                }
                BLOCK_GC_REF_NUMBER => {
                    let _len = d.read_len()?;
                }
                info => {
                    let has_origin = info & HAS_ORIGIN != 0;
                    let has_right = info & HAS_RIGHT_ORIGIN != 0;
                    if has_origin {
                        d.read_left_id()?;
                    }
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
                    let content = ItemContent::decode(&mut d, info)?;
                    if is_root {
                        out.push((client, content.len(OffsetKind::Utf16)));
                    }
                }
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::root_inserts;
    use yrs::updates::decoder::Decode;
    use yrs::{Doc, GetString, Map, ReadTxn, StateVector, Text, Transact, Update};

    fn state(doc: &Doc) -> Vec<u8> {
        doc.transact()
            .encode_state_as_update_v1(&StateVector::default())
    }

    fn clients(update: &[u8]) -> Vec<u64> {
        let mut c: Vec<u64> = root_inserts(update, "content")
            .unwrap()
            .into_iter()
            .map(|(c, _)| c)
            .collect();
        c.sort();
        c.dedup();
        c
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

    #[test]
    fn one_lineage_with_edits_is_one_root_client() {
        let a = seeded(1, "first body line.\n");
        let b = Doc::with_client_id(2);
        apply(&b, &state(&a));
        let t = b.get_or_insert_text("content");
        t.insert(&mut b.transact_mut(), 17, "second line.\n");
        t.insert(&mut b.transact_mut(), 0, "# title\n");
        assert_eq!(clients(&state(&b)), vec![1]);
    }

    #[test]
    fn a_fresh_client_seeding_an_existing_note_is_two() {
        let a = seeded(1, "first body line.\n");
        let fresh = seeded(2, "first body line.\nsecond line.\n");
        apply(&a, &state(&fresh));
        let body = a.get_or_insert_text("content").get_string(&a.transact());
        assert_eq!(body.matches("first body line.").count(), 2); // the doubling
        let roots = root_inserts(&state(&a), "content").unwrap();
        assert_eq!(clients(&state(&a)), vec![1, 2]);
        assert!(roots.contains(&(2, 30)));
    }

    #[test]
    fn clearing_and_retyping_mints_no_new_root() {
        let a = seeded(1, "old text");
        let b = Doc::with_client_id(2);
        apply(&b, &state(&a));
        let t = b.get_or_insert_text("content");
        t.remove_range(&mut b.transact_mut(), 0, 8);
        t.insert(&mut b.transact_mut(), 0, "new text");
        assert_eq!(clients(&state(&b)), vec![1]);
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
        assert_eq!(clients(&state(&a)), vec![1]);
    }

    #[test]
    fn empty_and_malformed_updates() {
        assert_eq!(clients(&state(&Doc::new())), Vec::<u64>::new());
        assert!(root_inserts(&[0xff, 0xff, 0xff], "content").is_err());
    }
}
