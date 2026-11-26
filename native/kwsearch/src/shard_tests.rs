//! Shard unit and property tests (no Postgres): out-of-order apply, crash
//! and reopen, maintained per-user stats, user-scoped deletes, tombstones,
//! marker expiry and the purge.

use crate::row::Row;
use crate::shard::{fnv, id, shard_of, Applied, BulkNote, Shard, BULK_MAX_AGE_S, MARKER_HOLD_S};
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::Path;
use uuid::Uuid;

const MB: usize = 15;
const TTL: u64 = 30 * 86_400;
const NOW: u64 = 1_800_000_000;

/// A scratch index dir, in RAM when the host has /dev/shm: every shard
/// commit fsyncs, which on a disk-backed tmp made the property run minutes long.
pub fn tmp() -> tempfile::TempDir {
    let shm = std::path::Path::new("/dev/shm");
    if shm.is_dir() {
        tempfile::tempdir_in(shm)
    } else {
        tempfile::tempdir()
    }
    .unwrap()
}

fn u(n: u64) -> Uuid {
    Uuid::from_u64_pair(0xabc, n)
}

fn terms_of(p: &Uuid) -> Vec<u8> {
    let h = fnv(p.as_bytes());
    kwfeed::pack((0..3 + h % 5).map(|i| ((h >> (i * 3)) as u32 % 40, 1 + (i as u32 % 3))))
}

fn len_of(terms: &[u8]) -> u64 {
    kwfeed::unpack(terms)
        .unwrap()
        .iter()
        .map(|p| p.1 as u64)
        .sum()
}

struct Rows {
    seq: i64,
    out: Vec<Row>,
}

impl Rows {
    fn new() -> Rows {
        Rows {
            seq: 0,
            out: Vec::new(),
        }
    }
    #[allow(clippy::too_many_arguments)]
    fn push(
        &mut self,
        xid: u64,
        xmax: u64,
        user: Uuid,
        op: i16,
        vault: Option<Uuid>,
        note: Option<Uuid>,
        point: Option<Uuid>,
        stamp: i64,
        keep: Option<Vec<Uuid>>,
    ) {
        self.seq += 1;
        let terms = (op == kwfeed::UPSERT).then(|| terms_of(&point.unwrap()));
        self.out.push(Row {
            seq: self.seq,
            xid,
            xmax,
            user,
            gen: 1,
            op,
            vault,
            note,
            point,
            stamp,
            terms,
            keep,
        });
    }
}

fn apply_all(s: &Shard, rows: &[Row]) {
    let refs: Vec<&Row> = rows.iter().collect();
    s.apply(&refs, MB, NOW).unwrap();
    let last = rows
        .iter()
        .map(|r| (r.xid, r.seq))
        .max()
        .unwrap_or_default();
    s.commit(last, 0, NOW, TTL).unwrap();
}

fn points(s: &Shard) -> HashSet<Uuid> {
    s.dump().into_iter().map(|d| d.0).collect()
}

fn hits(s: &Shard, user: &Uuid, vault: &Uuid, terms: &[u32]) -> Vec<(Uuid, f32)> {
    s.search(user, &[*vault], terms, None, &[], 100).unwrap()
}

// Task 4a: the exact 2-point-loss sequence from the POC crash run. Pass A
// (stamp 1) commits FIRST but holds the HIGHER xid; pass B (stamp 2) keeps
// A's chunk K unchanged, so B writes no row for K. xid order applies B,
// then A: A is stale, but K is in B's keep set and not indexed, so A's
// upsert of K must still land. The old "skip any older stamp" rule lost K.
#[test]
fn stale_pass_fills_a_point_the_newer_pass_kept() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (user, vault, note) = (u(1), u(2), u(3));
    let (k, x, y) = (u(10), u(11), u(12));
    let mut r = Rows::new();
    // B: lower xid, stamp 2.
    r.push(
        10,
        30,
        user,
        kwfeed::DELETE_NOTE_EXCEPT,
        Some(vault),
        Some(note),
        None,
        2,
        Some(vec![k, y]),
    );
    r.push(
        10,
        30,
        user,
        kwfeed::UPSERT,
        Some(vault),
        Some(note),
        Some(y),
        2,
        None,
    );
    // A: higher xid, stamp 1, committed first.
    r.push(
        20,
        30,
        user,
        kwfeed::DELETE_NOTE_EXCEPT,
        Some(vault),
        Some(note),
        None,
        1,
        Some(vec![k, x]),
    );
    r.push(
        20,
        30,
        user,
        kwfeed::UPSERT,
        Some(vault),
        Some(note),
        Some(k),
        1,
        None,
    );
    r.push(
        20,
        30,
        user,
        kwfeed::UPSERT,
        Some(vault),
        Some(note),
        Some(x),
        1,
        None,
    );
    apply_all(&s, &r.out);
    assert_eq!(points(&s), HashSet::from([k, y]));
}

// A vault or user delete between a newer pass and a stale one (same round,
// same shard) must not forget the newer pass's uncommitted marker: the POC
// cleared every marker there, so the stale pass read the older committed
// marker, applied as fresh and deleted the newer pass's points (property
// test, seed 1130 of 3000).
#[test]
fn a_vault_delete_between_passes_keeps_the_newer_marker() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (user, vault, note, other_vault) = (u(1), u(2), u(3), u(4));
    let (old, a, b) = (u(10), u(11), u(12));
    let mut r = Rows::new();
    r.push(
        1,
        2,
        user,
        kwfeed::DELETE_NOTE_EXCEPT,
        Some(vault),
        Some(note),
        None,
        1,
        Some(vec![old]),
    );
    r.push(
        1,
        2,
        user,
        kwfeed::UPSERT,
        Some(vault),
        Some(note),
        Some(old),
        1,
        None,
    );
    apply_all(&s, &r.out);
    let mut r = Rows {
        seq: 10,
        out: vec![],
    };
    // Stamp 3 took the lower xid; stamp 2 committed before it.
    r.push(
        5,
        9,
        user,
        kwfeed::DELETE_NOTE_EXCEPT,
        Some(vault),
        Some(note),
        None,
        3,
        Some(vec![a, b]),
    );
    r.push(
        5,
        9,
        user,
        kwfeed::UPSERT,
        Some(vault),
        Some(note),
        Some(a),
        3,
        None,
    );
    r.push(
        5,
        9,
        user,
        kwfeed::UPSERT,
        Some(vault),
        Some(note),
        Some(b),
        3,
        None,
    );
    r.push(
        6,
        9,
        user,
        kwfeed::DELETE_VAULT,
        Some(other_vault),
        None,
        None,
        0,
        None,
    );
    r.push(
        8,
        9,
        user,
        kwfeed::DELETE_NOTE_EXCEPT,
        Some(vault),
        Some(note),
        None,
        2,
        Some(vec![old]),
    );
    apply_all(&s, &r.out);
    assert_eq!(points(&s), HashSet::from([a, b]));
}

// Review #1 guard: an upsert at the marker's stamp for a point outside that
// pass's keep set (a keep set read before a newer pass committed) is dropped,
// never indexed.
#[test]
fn an_upsert_outside_its_passs_keep_set_is_dropped() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (user, vault, note, kept, stray) = (u(1), u(2), u(3), u(10), u(11));
    let mut r = Rows::new();
    r.push(
        1,
        2,
        user,
        kwfeed::DELETE_NOTE_EXCEPT,
        Some(vault),
        Some(note),
        None,
        2,
        Some(vec![kept]),
    );
    r.push(
        1,
        2,
        user,
        kwfeed::UPSERT,
        Some(vault),
        Some(note),
        Some(kept),
        2,
        None,
    );
    r.push(
        1,
        2,
        user,
        kwfeed::UPSERT,
        Some(vault),
        Some(note),
        Some(stray),
        2,
        None,
    );
    apply_all(&s, &r.out);
    assert_eq!(points(&s), HashSet::from([kept]));
    // Also against the committed marker in a later round.
    let mut r = Rows {
        seq: 10,
        out: vec![],
    };
    r.push(
        3,
        4,
        user,
        kwfeed::UPSERT,
        Some(vault),
        Some(note),
        Some(stray),
        2,
        None,
    );
    apply_all(&s, &r.out);
    assert_eq!(points(&s), HashSet::from([kept]));
}

// Review #11: an unreadable commit payload fails the open instead of
// resetting the cursor and dropping every tombstone.
#[test]
fn an_unreadable_payload_fails_the_open() {
    let dir = tmp();
    {
        let s = Shard::open(dir.path()).unwrap();
        let mut r = Rows::new();
        r.push(1, 2, u(1), kwfeed::DELETE_USER, None, None, None, 0, None);
        apply_all(&s, &r.out);
    }
    let meta = dir.path().join("meta.json");
    let text = std::fs::read_to_string(&meta).unwrap();
    let mut v: serde_json::Value = serde_json::from_str(&text).unwrap();
    v["payload"] = serde_json::json!("{not json");
    std::fs::write(&meta, v.to_string()).unwrap();
    assert!(Shard::open(dir.path()).is_err());
}

// Review N2: a malformed row (ragged terms, a note op without its note) is
// skipped and counted; the rows around it still apply and apply returns Ok.
#[test]
fn a_malformed_row_is_skipped_not_fatal() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (user, vault) = (u(1), u(2));
    let mut r = Rows::new();
    r.push(
        1,
        2,
        user,
        kwfeed::UPSERT,
        Some(vault),
        Some(u(3)),
        Some(u(10)),
        1,
        None,
    );
    r.push(
        1,
        2,
        user,
        kwfeed::UPSERT,
        Some(vault),
        Some(u(4)),
        Some(u(11)),
        1,
        None,
    );
    r.out[1].terms = Some(vec![1, 2, 3]); // not a multiple of 8
    r.push(
        1,
        2,
        user,
        kwfeed::DELETE_NOTE,
        Some(vault),
        None,
        None,
        1,
        None,
    );
    r.push(
        1,
        2,
        user,
        kwfeed::UPSERT,
        Some(vault),
        Some(u(5)),
        Some(u(12)),
        1,
        None,
    );
    let refs: Vec<&Row> = r.out.iter().collect();
    let a = s.apply(&refs, MB, NOW).unwrap();
    assert_eq!(a.skipped_malformed, 2);
    s.commit((1, 4), 0, NOW, TTL).unwrap();
    assert_eq!(points(&s), HashSet::from([u(10), u(12)]));
}

// Task 4c: two users whose 32-bit dims collide in one shard. Each user's
// document frequency, and so each score, is unchanged by the other.
#[test]
fn colliding_dims_of_two_users_do_not_mix() {
    let a = u(100);
    let b = (101..)
        .map(u)
        .find(|b| shard_of(b) == shard_of(&a))
        .unwrap();
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (va, vb) = (u(200), u(201));
    let mut r = Rows::new();
    for i in 0..5u64 {
        let p = Uuid::from_u64_pair(1, i);
        r.push(
            1,
            2,
            a,
            kwfeed::UPSERT,
            Some(va),
            Some(u(300 + i)),
            Some(p),
            1,
            None,
        );
    }
    apply_all(&s, &r.out);
    let dims: Vec<u32> = kwfeed::unpack(&terms_of(&Uuid::from_u64_pair(1, 0)))
        .unwrap()
        .iter()
        .map(|p| p.0)
        .collect();
    let before = hits(&s, &a, &va, &dims);
    assert!(!before.is_empty());
    // B floods the same dims in the same shard.
    let mut r = Rows::new();
    r.seq = 100;
    for i in 0..200u64 {
        let p = Uuid::from_u64_pair(1, i); // same terms as A's points
        let mut row = Row {
            seq: 0,
            xid: 5,
            xmax: 6,
            user: b,
            gen: 1,
            op: kwfeed::UPSERT,
            vault: Some(vb),
            note: Some(u(900 + i)),
            point: Some(Uuid::from_u64_pair(2, i)),
            stamp: 1,
            terms: Some(terms_of(&p)),
            keep: None,
        };
        r.seq += 1;
        row.seq = r.seq;
        r.out.push(row);
    }
    apply_all(&s, &r.out);
    assert_eq!(hits(&s, &a, &va, &dims), before);
    assert!(
        hits(&s, &a, &vb, &dims).is_empty(),
        "A naming B's vault gets nothing"
    );
    assert_eq!(hits(&s, &b, &vb, &dims).len(), 100);
}

// Security F7: a row for user B that names user A's vault, note or point
// deletes nothing of A's.
#[test]
fn deletes_are_scoped_by_user() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (a, b, va, na, pa) = (u(1), u(2), u(3), u(4), u(5));
    let mut r = Rows::new();
    r.push(
        1,
        2,
        a,
        kwfeed::UPSERT,
        Some(va),
        Some(na),
        Some(pa),
        1,
        None,
    );
    apply_all(&s, &r.out);
    let mut r = Rows {
        seq: 10,
        out: vec![],
    };
    r.push(
        3,
        4,
        b,
        kwfeed::DELETE_POINTS,
        None,
        None,
        Some(pa),
        0,
        None,
    );
    r.push(
        3,
        4,
        b,
        kwfeed::DELETE_POINTS,
        Some(va),
        Some(na),
        Some(pa),
        9,
        None,
    );
    r.push(
        3,
        4,
        b,
        kwfeed::DELETE_NOTE,
        Some(va),
        Some(na),
        None,
        9,
        None,
    );
    r.push(
        3,
        4,
        b,
        kwfeed::DELETE_NOTE_EXCEPT,
        Some(va),
        Some(na),
        None,
        10,
        Some(vec![]),
    );
    r.push(3, 4, b, kwfeed::DELETE_VAULT, Some(va), None, None, 0, None);
    apply_all(&s, &r.out);
    assert_eq!(points(&s), HashSet::from([pa]));
    assert_eq!(s.user_stats(&a), (1, len_of(&terms_of(&pa))));
}

// A late upsert (higher xid, committed before the delete) never brings a
// deleted user or vault back, also after a reopen; tombstones expire after
// their TTL (F12).
#[test]
fn tombstones_drop_late_upserts_and_expire() {
    let dir = tmp();
    let (a, va, vb) = (u(1), u(2), u(3));
    {
        let s = Shard::open(dir.path()).unwrap();
        let mut r = Rows::new();
        r.push(
            1,
            2,
            a,
            kwfeed::UPSERT,
            Some(vb),
            Some(u(5)),
            Some(u(6)),
            1,
            None,
        );
        r.push(2, 3, a, kwfeed::DELETE_VAULT, Some(vb), None, None, 0, None);
        r.push(
            3,
            4,
            a,
            kwfeed::UPSERT,
            Some(vb),
            Some(u(5)),
            Some(u(7)),
            2,
            None,
        );
        r.push(4, 5, a, kwfeed::DELETE_USER, None, None, None, 0, None);
        apply_all(&s, &r.out);
    }
    let s = Shard::open(dir.path()).unwrap();
    let mut r = Rows {
        seq: 10,
        out: vec![],
    };
    r.push(
        5,
        6,
        a,
        kwfeed::UPSERT,
        Some(va),
        Some(u(8)),
        Some(u(9)),
        1,
        None,
    );
    apply_all(&s, &r.out);
    assert!(points(&s).is_empty());
    assert_eq!(s.user_stats(&a), (0, 0));
    // TTL passes: the next commit forgets the account ever existed.
    let mut r = Rows {
        seq: 20,
        out: vec![],
    };
    r.push(
        6,
        7,
        u(50),
        kwfeed::UPSERT,
        Some(u(51)),
        Some(u(52)),
        Some(u(53)),
        1,
        None,
    );
    let refs: Vec<&Row> = r.out.iter().collect();
    s.apply(&refs, MB, NOW).unwrap();
    s.commit((6, 21), 0, NOW + TTL + 1, TTL).unwrap();
    let st = s.state.lock().unwrap();
    assert!(st.meta.tomb_users.is_empty() && st.meta.tomb_vaults.is_empty());
}

// Task 4g: a marker lives only until every row below its snapshot's xmax is
// applied, so the marker set tracks notes in flight, not the corpus.
#[test]
fn markers_expire_once_the_watermark_passes() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let mut r = Rows::new();
    r.push(
        10,
        15,
        u(1),
        kwfeed::DELETE_NOTE_EXCEPT,
        Some(u(2)),
        Some(u(3)),
        None,
        1,
        Some(vec![u(4)]),
    );
    r.push(
        10,
        15,
        u(1),
        kwfeed::UPSERT,
        Some(u(2)),
        Some(u(3)),
        Some(u(4)),
        1,
        None,
    );
    let refs: Vec<&Row> = r.out.iter().collect();
    s.apply(&refs, MB, NOW).unwrap();
    s.commit((10, 2), 12, NOW, TTL).unwrap();
    let markers = |s: &Shard| {
        s.reader
            .searcher()
            .doc_freq(&tantivy::Term::from_field_text(s.f.mnote, &id(&u(3))))
            .unwrap()
    };
    assert_eq!(
        markers(&s),
        1,
        "kept while rows below xmax 15 may still arrive"
    );
    let mut r = Rows {
        seq: 5,
        out: vec![],
    };
    r.push(
        16,
        17,
        u(9),
        kwfeed::UPSERT,
        Some(u(8)),
        Some(u(7)),
        Some(u(6)),
        1,
        None,
    );
    let refs: Vec<&Row> = r.out.iter().collect();
    s.apply(&refs, MB, NOW).unwrap();
    s.commit((16, 6), 16, NOW, TTL).unwrap();
    assert_eq!(
        markers(&s),
        1,
        "past the watermark but held for the bulk window (MARKER_HOLD_S)"
    );
    let later = NOW + MARKER_HOLD_S;
    let mut r = Rows {
        seq: 6,
        out: vec![],
    };
    r.push(
        18,
        19,
        u(9),
        kwfeed::UPSERT,
        Some(u(8)),
        Some(u(7)),
        Some(u(5)),
        2,
        None,
    );
    let refs: Vec<&Row> = r.out.iter().collect();
    s.apply(&refs, MB, later).unwrap();
    s.commit((18, 7), 18, later, TTL).unwrap();
    assert!(s.purge(MB).unwrap());
    s.commit((18, 7), 18, later, TTL).unwrap();
    assert_eq!(markers(&s), 0);
    assert_eq!(points(&s), HashSet::from([u(4), u(5), u(6)]));
}

/// Every term of every field in every live segment, as strings/bytes, and
/// whether every segment file on disk belongs to a live segment.
fn segment_terms_and_orphans(dir: &Path) -> (Vec<Vec<u8>>, Vec<String>) {
    let s = Shard::open(dir).unwrap();
    let searcher = s.reader.searcher();
    let mut terms = Vec::new();
    let mut live = HashSet::new();
    for seg in searcher.segment_readers() {
        live.insert(seg.segment_id().uuid_string());
        for (field, _) in s.index.schema().fields() {
            let inv = seg.inverted_index(field).unwrap();
            let mut st = inv.terms().stream().unwrap();
            while st.advance() {
                terms.push(st.key().to_vec());
            }
        }
    }
    let orphans = std::fs::read_dir(dir)
        .unwrap()
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|n| n.len() > 32 && n.as_bytes()[..32].iter().all(u8::is_ascii_hexdigit))
        .filter(|n| !live.contains(&n[..32]))
        .collect();
    (terms, orphans)
}

// Security F1: after delete_user and the purge, the user's id prefix is in
// no term dictionary of any segment, and no file of a merged-away segment
// is left on disk.
#[test]
fn purge_removes_a_deleted_users_terms_from_disk() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (gone, kept) = (u(1), u(2));
    for round in 0..3u64 {
        let mut r = Rows {
            seq: (round * 100) as i64,
            out: vec![],
        };
        for i in 0..20u64 {
            for user in [gone, kept] {
                r.push(
                    round + 1,
                    round + 2,
                    user,
                    kwfeed::UPSERT,
                    Some(Uuid::from_u64_pair(user.as_u64_pair().1, 9)),
                    Some(Uuid::from_u64_pair(user.as_u64_pair().1, i)),
                    Some(Uuid::from_u128(
                        fnv(&[round as u8, i as u8, user.as_u64_pair().1 as u8]) as u128,
                    )),
                    1,
                    None,
                );
            }
        }
        apply_all(&s, &r.out); // one segment per round
    }
    let prefix = id(&gone).into_bytes();
    let has = |terms: &[Vec<u8>]| {
        terms
            .iter()
            .any(|t| t.windows(prefix.len()).any(|w| w == prefix.as_slice()))
    };
    assert!(has(&segment_terms_and_orphans(dir.path()).0));
    let mut r = Rows {
        seq: 1000,
        out: vec![],
    };
    r.push(10, 11, gone, kwfeed::DELETE_USER, None, None, None, 0, None);
    let refs: Vec<&Row> = r.out.iter().collect();
    s.apply(&refs, MB, NOW).unwrap();
    s.commit((10, 1001), 11, NOW, TTL).unwrap();
    assert!(s.state.lock().unwrap().purge_now);
    assert!(s.first_delete_at().is_some());
    assert!(s.purge(MB).unwrap());
    s.commit((10, 1001), 11, NOW, TTL).unwrap();
    assert!(s.first_delete_at().is_none());
    s.close_writer();
    drop(s);
    let (terms, orphans) = segment_terms_and_orphans(dir.path());
    assert!(
        !has(&terms),
        "deleted user's prefix still in a term dictionary"
    );
    assert!(
        orphans.is_empty(),
        "files of merged-away segments left: {orphans:?}"
    );
    assert!(terms
        .iter()
        .any(|t| t.windows(32).any(|w| w == id(&kept).as_bytes())));
}

// Boot restore: the deletion log removes docs a restored snapshot still
// holds, before any search.
#[test]
fn deletion_log_applies_on_a_restored_shard() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (a, b, va, vb, n) = (u(1), u(2), u(3), u(4), u(5));
    let mut r = Rows::new();
    r.push(
        1,
        2,
        a,
        kwfeed::UPSERT,
        Some(va),
        Some(n),
        Some(u(10)),
        1,
        None,
    );
    r.push(
        1,
        2,
        a,
        kwfeed::UPSERT,
        Some(va),
        Some(u(6)),
        Some(u(11)),
        1,
        None,
    );
    r.push(
        1,
        2,
        b,
        kwfeed::UPSERT,
        Some(vb),
        Some(u(7)),
        Some(u(12)),
        1,
        None,
    );
    r.push(
        1,
        2,
        b,
        kwfeed::UPSERT,
        Some(u(8)),
        Some(u(9)),
        Some(u(13)),
        1,
        None,
    );
    apply_all(&s, &r.out);
    assert!(s
        .apply_deletion(kwfeed::DELETE_NOTE, &a, Some(va), Some(n), MB, NOW)
        .unwrap());
    assert!(s
        .apply_deletion(kwfeed::DELETE_VAULT, &b, Some(vb), None, MB, NOW)
        .unwrap());
    s.commit(s.cursor(), 0, NOW, TTL).unwrap();
    assert_eq!(points(&s), HashSet::from([u(11), u(13)]));
    assert!(s
        .apply_deletion(kwfeed::DELETE_USER, &b, None, None, MB, NOW)
        .unwrap());
    s.commit(s.cursor(), 0, NOW, TTL).unwrap();
    assert_eq!(points(&s), HashSet::from([u(11)]));
    assert_eq!(s.user_stats(&a), (1, len_of(&terms_of(&u(11)))));
}

// Task 4 (maintained stats): scores use the user's own N and avgdl, read
// from the stats doc, identical whether the user is alone in the shard or
// shares it with many others.
#[test]
fn per_user_stats_make_shared_and_alone_scores_equal() {
    let mk = |fillers: u64| {
        let dir = tmp();
        let s = Shard::open(dir.path()).unwrap();
        let mut r = Rows::new();
        for i in 0..30u64 {
            r.push(
                1,
                2,
                u(1),
                kwfeed::UPSERT,
                Some(u(2)),
                Some(Uuid::from_u64_pair(3, i % 7)),
                Some(Uuid::from_u64_pair(4, i)),
                1,
                None,
            );
        }
        for f in 0..fillers {
            for i in 0..40u64 {
                r.push(
                    1,
                    2,
                    Uuid::from_u64_pair(9, f),
                    kwfeed::UPSERT,
                    Some(Uuid::from_u64_pair(8, f)),
                    Some(Uuid::from_u64_pair(7, i)),
                    Some(Uuid::from_u64_pair(6, f * 1000 + i)),
                    1,
                    None,
                );
            }
        }
        apply_all(&s, &r.out);
        (dir, s)
    };
    let (_d1, alone) = mk(0);
    let (_d2, shared) = mk(25);
    for t in 0..40u32 {
        assert_eq!(
            hits(&alone, &u(1), &u(2), &[t]),
            hits(&shared, &u(1), &u(2), &[t]),
            "term {t}"
        );
    }
}

/// Truth of the property run: point -> (user, vault, terms).
type Truth = BTreeMap<Uuid, (Uuid, Uuid, Vec<u8>)>;

/// One feed row of a generated transaction, before it gets an xid:
/// (op, user, vault, note, point, stamp, keep).
type Op = (
    i16,
    Uuid,
    Option<Uuid>,
    Option<Uuid>,
    Option<Uuid>,
    i64,
    Option<Vec<Uuid>>,
);

// Property (tasks 4a, 4d, 4g, F7): a random edit/delete workload whose
// transactions take xids out of commit order, applied in xid order in
// random batches with random crashes (drop without commit, reopen from
// disk), ends with exactly the truth: same points, same terms, and each
// user's maintained stats equal a scan of the truth.
#[test]
fn random_out_of_order_workload_with_crashes_matches_truth() {
    let only: Option<u64> = std::env::var("KW_SEED").ok().and_then(|v| v.parse().ok());
    // KW_SEEDS widens the run (CI keeps 60).
    let n: u64 = std::env::var("KW_SEEDS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(60);
    for seed in (0..n).filter(|s| only.is_none_or(|o| o == *s)) {
        run_property(seed);
    }
}

fn run_property(seed: u64) {
    let mut rng = StdRng::seed_from_u64(seed);
    let users: Vec<Uuid> = (0..3).map(|i| Uuid::from_u64_pair(seed + 1, i)).collect();
    let vault = |user: &Uuid, k: u64| Uuid::from_u64_pair(user.as_u64_pair().1 + 100, k);
    let mut truth: Truth = BTreeMap::new();
    let mut note_pts: HashMap<Uuid, BTreeSet<Uuid>> = HashMap::new();
    let mut stamps: HashMap<Uuid, i64> = HashMap::new();
    let mut dead_users = HashSet::new();
    let mut dead_vaults = HashSet::new();
    // (commit order index, rows without xid) per transaction.
    let mut txns: Vec<Vec<Op>> = Vec::new();
    // Bulk batches (backfill, reconcile): a note's truth read under its
    // lock at a point in commit order, with the next stamp of the note,
    // pushed at a random later point of the apply (before or after feed
    // rows of earlier and later transactions, deletes included).
    let mut owner: HashMap<Uuid, (Uuid, Uuid)> = HashMap::new();
    let mut bulks: Vec<(usize, Uuid, BulkNote)> = Vec::new();
    for _ in 0..rng.random_range(40..120) {
        let user = users[rng.random_range(0..users.len())];
        let v = vault(&user, rng.random_range(0..2));
        if dead_users.contains(&user) || dead_vaults.contains(&v) {
            continue;
        }
        let note = Uuid::from_u64_pair(
            v.as_u64_pair().0,
            v.as_u64_pair().1 * 10 + rng.random_range(0..3),
        );
        let mut ops = Vec::new();
        let roll = rng.random_range(0..100);
        if roll < 2 {
            dead_users.insert(user);
            truth.retain(|_, t| t.0 != user);
            ops.push((kwfeed::DELETE_USER, user, None, None, None, 0, None));
        } else if roll < 5 {
            dead_vaults.insert(v);
            truth.retain(|_, t| t.1 != v);
            ops.push((kwfeed::DELETE_VAULT, user, Some(v), None, None, 0, None));
        } else {
            let stamp = {
                let s = stamps.entry(note).or_default();
                *s += 1;
                *s
            };
            let have: BTreeSet<Uuid> = note_pts
                .get(&note)
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .filter(|p| truth.contains_key(p))
                .collect();
            if roll < 15 {
                for p in &have {
                    truth.remove(p);
                }
                note_pts.remove(&note);
                ops.push((
                    kwfeed::DELETE_NOTE,
                    user,
                    Some(v),
                    Some(note),
                    None,
                    stamp,
                    None,
                ));
            } else if roll < 25 {
                let gone: Vec<Uuid> = have
                    .iter()
                    .filter(|_| rng.random_bool(0.5))
                    .copied()
                    .collect();
                let keep: Vec<Uuid> = have.iter().filter(|p| !gone.contains(p)).copied().collect();
                ops.push((
                    kwfeed::DELETE_NOTE_EXCEPT,
                    user,
                    Some(v),
                    Some(note),
                    None,
                    stamp,
                    Some(keep),
                ));
                for p in gone {
                    truth.remove(&p);
                    ops.push((
                        kwfeed::DELETE_POINTS,
                        user,
                        Some(v),
                        Some(note),
                        Some(p),
                        stamp,
                        None,
                    ));
                }
            } else {
                // Edit: keep some, drop some, add 1-3 (content-derived ids
                // from a small alphabet, so an old chunk can come back).
                let mut keep: BTreeSet<Uuid> = have
                    .iter()
                    .filter(|_| rng.random_bool(0.6))
                    .copied()
                    .collect();
                let new: Vec<Uuid> = (0..rng.random_range(1..4))
                    .map(|_| Uuid::from_u64_pair(fnv(note.as_bytes()), rng.random_range(0..8)))
                    .filter(|p| !keep.contains(p))
                    .collect();
                keep.extend(new.iter().copied());
                for p in have.difference(&keep) {
                    truth.remove(p);
                }
                ops.push((
                    kwfeed::DELETE_NOTE_EXCEPT,
                    user,
                    Some(v),
                    Some(note),
                    None,
                    stamp,
                    Some(keep.iter().copied().collect()),
                ));
                let mut seen = BTreeSet::new();
                for p in new {
                    if seen.insert(p) {
                        truth.insert(p, (user, v, terms_of(&p)));
                        ops.push((
                            kwfeed::UPSERT,
                            user,
                            Some(v),
                            Some(note),
                            Some(p),
                            stamp,
                            None,
                        ));
                    }
                }
                note_pts.insert(note, keep);
            }
        }
        owner.insert(note, (user, v));
        txns.push(ops);
        if rng.random_bool(0.25) && std::env::var("KW_NOBULK").is_err() {
            let live: Vec<Uuid> = note_pts.keys().copied().collect();
            if !live.is_empty() {
                let n = live[rng.random_range(0..live.len())];
                let (bu, bv) = owner[&n];
                if !dead_users.contains(&bu) && !dead_vaults.contains(&bv) {
                    let stamp = {
                        let s = stamps.entry(n).or_default();
                        *s += 1;
                        *s
                    };
                    let keep: Vec<Uuid> = note_pts[&n]
                        .iter()
                        .filter(|p| truth.contains_key(p))
                        .copied()
                        .collect();
                    let mut b = BulkNote {
                        vault: bv,
                        note: n,
                        stamp,
                        xmax: 0,
                        docs: keep.iter().map(|p| (*p, terms_of(p))).collect(),
                        keep,
                    };
                    b.xmax = txns.len() as u64; // fixed up to an xid below
                    bulks.push((txns.len() - 1, bu, b));
                }
            }
        }
    }
    // xids out of commit order (up to ~3 transactions apart); xmax of a row
    // = above every xid committed up to and including its transaction.
    let xids: Vec<u64> = (0..txns.len())
        .map(|i| (i as u64 * 4 + rng.random_range(0..13)) * 1000 + i as u64)
        .collect();
    let mut rows = Vec::new();
    let mut seq = 0;
    let mut max_xid = 0;
    let mut xmax_at = Vec::new();
    for (i, ops) in txns.iter().enumerate() {
        max_xid = max_xid.max(xids[i]);
        xmax_at.push(max_xid + 1);
        for (op, user, vault, note, point, stamp, keep) in ops {
            seq += 1;
            let terms = (*op == kwfeed::UPSERT).then(|| terms_of(&point.unwrap()));
            rows.push(Row {
                seq,
                xid: xids[i],
                xmax: max_xid + 1,
                user: *user,
                gen: 1,
                op: *op,
                vault: *vault,
                note: *note,
                point: *point,
                stamp: *stamp,
                terms,
                keep: keep.clone(),
            });
        }
    }
    rows.sort_by_key(|r| (r.xid, r.seq));
    let trace = std::env::var("KW_TRACE")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        == Some(seed);
    if trace {
        for (i, ops) in txns.iter().enumerate() {
            for o in ops {
                eprintln!("commit#{i} xid={} op={} user={} vault={:?} note={:?} point={:?} stamp={} keep={:?}", xids[i], o.0, o.1.as_u64_pair().1,
                    o.2.map(|x| x.as_u64_pair().1), o.3.map(|x| fnv(x.as_bytes()) as u32), o.4.map(|x| (x.as_u64_pair().0 as u32, x.as_u64_pair().1)), o.5,
                    o.6.as_ref().map(|k| k.iter().map(|x| x.as_u64_pair().1).collect::<Vec<_>>()));
            }
        }
    }
    if trace {
        for (i, r) in rows.iter().enumerate() {
            eprintln!(
                "row#{i} xid={} xmax={} op={} note={:?} point={:?} stamp={} keep={:?}",
                r.xid,
                r.xmax,
                r.op,
                r.note.map(|x| fnv(x.as_bytes()) as u16),
                r.point.map(|x| fnv(x.as_bytes()) as u16),
                r.stamp,
                r.keep.as_ref().map(|k| k
                    .iter()
                    .map(|x| fnv(x.as_bytes()) as u16)
                    .collect::<Vec<_>>())
            );
        }
    }
    for b in &mut bulks {
        b.2.xmax = xmax_at[b.0];
    }
    let mut pending: Vec<(Uuid, BulkNote)> = bulks.into_iter().map(|b| (b.1, b.2)).collect();
    let deliver = |s: &Shard, rng: &mut StdRng, pending: &mut Vec<(Uuid, BulkNote)>| {
        if !pending.is_empty() {
            let (user, n) = pending.remove(rng.random_range(0..pending.len()));
            if trace {
                eprintln!(
                    "BULK note={} stamp={}",
                    fnv(n.note.as_bytes()) as u16,
                    n.stamp
                );
            }
            s.bulk(&user, 1, &[n], MB, NOW).unwrap();
            s.commit_here(NOW, TTL).unwrap();
        }
    };
    let dir = tmp();
    let mut s = Shard::open(dir.path()).unwrap();
    // KW_BIG: one batch per round, the way a catch-up applies thousands of rows.
    let big = std::env::var("KW_BIG").is_ok();
    let mut at = 0;
    while at < rows.len() {
        let n = if big {
            rows.len() - at
        } else {
            rng.random_range(1..12).min(rows.len() - at)
        };
        let batch: Vec<&Row> = rows[at..at + n].iter().collect();
        s.apply(&batch, MB, NOW).unwrap();
        // A bulk push mid-round commits the round's applied rows at the
        // shard's old cursor; a crash after it replays them.
        if rng.random_bool(0.3) {
            deliver(&s, &mut rng, &mut pending);
        }
        if trace {
            eprintln!("batch {at}..{}", at + n);
        }
        if rng.random_bool(0.2) && std::env::var("KW_NOCRASH").is_err() {
            if trace {
                eprintln!("CRASH");
            }
            // Crash before this batch commits: reopen, resume from disk.
            s.crash();
            drop(s);
            s = Shard::open(dir.path()).unwrap();
            if trace {
                let segs: Vec<String> = s
                    .reader
                    .searcher()
                    .segment_readers()
                    .iter()
                    .map(|r| {
                        format!(
                            "{}:{}/{}",
                            &r.segment_id().uuid_string()[..6],
                            r.num_docs(),
                            r.num_deleted_docs()
                        )
                    })
                    .collect();
                eprintln!("  reopened segs {segs:?}");
            }
            let c = s.cursor();
            at = rows
                .iter()
                .position(|r| (r.xid, r.seq) > c)
                .unwrap_or(rows.len());
            continue;
        }
        let last = rows[at + n - 1].clone();
        s.commit((last.xid, last.seq), last.xid, NOW, TTL).unwrap();
        if trace {
            let mut v: Vec<u16> = s
                .dump()
                .iter()
                .map(|d| fnv(d.0.as_bytes()) as u16)
                .collect();
            v.sort();
            eprintln!("committed through row {} index={v:?}", at + n - 1);
            let segs: Vec<String> = s
                .reader
                .searcher()
                .segment_readers()
                .iter()
                .map(|r| {
                    format!(
                        "{}:{}/{}",
                        &r.segment_id().uuid_string()[..6],
                        r.num_docs(),
                        r.num_deleted_docs()
                    )
                })
                .collect();
            eprintln!("  segs {segs:?}");
            let owner: HashMap<Uuid, Uuid> = rows
                .iter()
                .filter_map(|r| r.point.map(|p| (p, r.user)))
                .collect();
            for user in &users {
                let mine: Vec<(Uuid, u64, u64)> = s
                    .dump()
                    .into_iter()
                    .filter(|d| owner.get(&d.0) == Some(user))
                    .collect();
                let scan = (mine.len() as u64, mine.iter().map(|d| d.1).sum::<u64>());
                if scan != s.user_stats(user) {
                    eprintln!(
                        "STATS DRIFT user {} after row {}: doc={:?} scan={scan:?}",
                        user.as_u64_pair().1,
                        at + n - 1,
                        s.user_stats(user)
                    );
                }
            }
        }
        if rng.random_bool(0.1) && std::env::var("KW_NOPURGE").is_err() {
            s.purge(MB).unwrap();
            s.commit((last.xid, last.seq), last.xid, NOW, TTL).unwrap();
            if trace {
                let mut v: Vec<u16> = s
                    .dump()
                    .iter()
                    .map(|d| fnv(d.0.as_bytes()) as u16)
                    .collect();
                v.sort();
                eprintln!("PURGE index={v:?}");
            }
        }
        at += n;
    }
    while !pending.is_empty() {
        deliver(&s, &mut rng, &mut pending);
    }
    let got: BTreeMap<Uuid, u64> = s.dump().into_iter().map(|(p, _, crc)| (p, crc)).collect();
    if trace {
        let mut c: HashMap<Uuid, usize> = HashMap::new();
        for d in s.dump() {
            *c.entry(d.0).or_default() += 1;
        }
        for (p, n) in c.iter().filter(|x| *x.1 > 1) {
            eprintln!("DUP {} x{n}", fnv(p.as_bytes()) as u16);
        }
    }
    let want: BTreeMap<Uuid, u64> = truth.iter().map(|(p, t)| (*p, fnv(&t.2))).collect();
    assert_eq!(got.len(), s.dump().len(), "seed {seed}: duplicate docs");
    if trace {
        for p in got.keys().filter(|p| !want.contains_key(p)) {
            eprintln!("EXTRA {}", fnv(p.as_bytes()) as u16);
        }
        for p in want.keys().filter(|p| !got.contains_key(p)) {
            eprintln!("MISSING {}", fnv(p.as_bytes()) as u16);
        }
    }
    assert_eq!(got, want, "seed {seed}: index differs from truth");
    for user in &users {
        let mine: Vec<&(Uuid, Uuid, Vec<u8>)> = truth.values().filter(|t| t.0 == *user).collect();
        let want = (mine.len() as u64, mine.iter().map(|t| len_of(&t.2)).sum());
        assert_eq!(s.user_stats(user), want, "seed {seed}: stats of {user}");
    }
}

// ---- Bulk batches (backfill, reconcile; roadmap P2 task 5) ----
//
// A bulk batch is read by the app under the note's row lock with a stamp
// from the same per-note sequence as the feed, then pushed later. Each test
// below interleaves one with live feed ops and fails without the check it
// names.

fn bulk_note(vault: Uuid, note: Uuid, stamp: i64, keep: &[Uuid]) -> BulkNote {
    BulkNote {
        vault,
        note,
        stamp,
        xmax: 1,
        keep: keep.to_vec(),
        docs: keep.iter().map(|p| (*p, terms_of(p))).collect(),
    }
}

fn push_bulk(s: &Shard, user: &Uuid, notes: &[BulkNote], now: u64) -> Applied {
    let a = s.bulk(user, 1, notes, MB, now).unwrap();
    s.commit_here(now, TTL).unwrap();
    a
}

/// A whole pass for `note` at `stamp`: delete_note_except(keep), then an
/// upsert per point in `new`.
#[allow(clippy::too_many_arguments)]
fn pass(
    r: &mut Rows,
    xid: u64,
    user: Uuid,
    vault: Uuid,
    note: Uuid,
    stamp: i64,
    keep: &[Uuid],
    new: &[Uuid],
) {
    r.push(
        xid,
        xid + 1,
        user,
        kwfeed::DELETE_NOTE_EXCEPT,
        Some(vault),
        Some(note),
        None,
        stamp,
        Some(keep.to_vec()),
    );
    for p in new {
        r.push(
            xid,
            xid + 1,
            user,
            kwfeed::UPSERT,
            Some(vault),
            Some(note),
            Some(*p),
            stamp,
            None,
        );
    }
}

// Ordering check: the batch was read at stamp 1 (note held A), an edit at
// stamp 2 replaced A with B and was applied first. Without the stamp check
// the batch's keep set deletes B and its doc brings A back.
#[test]
fn a_bulk_batch_older_than_an_applied_edit_is_dropped() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (user, vault, note, a, b) = (u(1), u(2), u(3), u(10), u(11));
    let mut r = Rows::new();
    pass(&mut r, 5, user, vault, note, 2, &[b], &[b]);
    apply_all(&s, &r.out);
    let got = push_bulk(&s, &user, &[bulk_note(vault, note, 1, &[a])], NOW);
    assert_eq!(points(&s), HashSet::from([b]));
    assert_eq!((got.applied, got.skipped_stale), (0, 1));
    assert_eq!(s.user_stats(&user), (1, len_of(&terms_of(&b))));
}

// Ordering check on a delete: the note was trashed (stamp 2) after the
// batch read it (stamp 1). Without it the deleted note comes back.
#[test]
fn a_bulk_batch_older_than_a_note_delete_is_dropped() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (user, vault, note, a) = (u(1), u(2), u(3), u(10));
    let mut r = Rows::new();
    pass(&mut r, 4, user, vault, note, 1, &[a], &[a]);
    r.push(
        6,
        7,
        user,
        kwfeed::DELETE_NOTE,
        Some(vault),
        Some(note),
        None,
        2,
        None,
    );
    apply_all(&s, &r.out);
    assert!(points(&s).is_empty());
    let got = push_bulk(&s, &user, &[bulk_note(vault, note, 1, &[a])], NOW);
    assert!(
        points(&s).is_empty(),
        "a deleted note came back from a bulk batch"
    );
    assert_eq!(got.skipped_stale, 1);
    assert_eq!(s.user_stats(&user), (0, 0));
}

// The marker hold: once the feed's watermark passes a note's op, its
// marker used to expire at once. A batch read before that op and pushed
// later (up to BULK_MAX_AGE_S) then found no marker and resurrected a
// point the op removed. The marker now outlives the watermark by
// MARKER_HOLD_S, then goes.
#[test]
fn note_markers_outlive_the_watermark_for_the_bulk_window() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (user, vault, note, a, b) = (u(1), u(2), u(3), u(10), u(11));
    let mut r = Rows::new();
    pass(&mut r, 4, user, vault, note, 1, &[a, b], &[a, b]);
    // Stamp 3: a pass that only drops A (no upsert carries its stamp).
    pass(&mut r, 6, user, vault, note, 3, &[b], &[]);
    let refs: Vec<&Row> = r.out.iter().collect();
    s.apply(&refs, MB, NOW).unwrap();
    // Watermark past every row's xmax: the feed needs no marker any more.
    s.commit((6, r.seq), 100, NOW, TTL).unwrap();
    let late = NOW + BULK_MAX_AGE_S;
    s.commit_here(late, TTL).unwrap();
    // Read at stamp 2 (A and B), pushed an hour later.
    let got = push_bulk(&s, &user, &[bulk_note(vault, note, 2, &[a, b])], late);
    assert_eq!(points(&s), HashSet::from([b]), "a removed point came back");
    assert_eq!(got.skipped_stale, 1);
    // Past the hold the marker goes (the batch age bound refuses anything
    // read before it).
    let markers = || {
        s.reader
            .searcher()
            .doc_freq(&tantivy::Term::from_field_text(s.f.mnote, &id(&note)))
            .unwrap()
    };
    assert_eq!(markers(), 1);
    let mut r2 = Rows {
        seq: 50,
        out: vec![],
    };
    r2.push(
        200,
        201,
        u(9),
        kwfeed::UPSERT,
        Some(u(8)),
        Some(u(7)),
        Some(u(6)),
        1,
        None,
    );
    let refs: Vec<&Row> = r2.out.iter().collect();
    s.apply(&refs, MB, NOW + MARKER_HOLD_S + 1).unwrap();
    s.commit((200, 51), 200, NOW + MARKER_HOLD_S + 1, TTL)
        .unwrap();
    assert!(s.purge(MB).unwrap());
    s.commit_here(NOW + MARKER_HOLD_S + 1, TTL).unwrap();
    assert_eq!(markers(), 0);
}

// Tombstone check: the batch was read before the user (or the vault) was
// deleted. Without it the deleted account's docs come back.
#[test]
fn a_bulk_batch_for_a_tombstoned_user_or_vault_is_dropped() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (gone_user, v1, kept_user, v2, v3) = (u(1), u(2), u(3), u(4), u(5));
    let mut r = Rows::new();
    r.push(
        4,
        5,
        gone_user,
        kwfeed::DELETE_USER,
        None,
        None,
        None,
        0,
        None,
    );
    r.push(
        4,
        5,
        kept_user,
        kwfeed::DELETE_VAULT,
        Some(v2),
        None,
        None,
        0,
        None,
    );
    apply_all(&s, &r.out);
    let a = push_bulk(&s, &gone_user, &[bulk_note(v1, u(20), 1, &[u(30)])], NOW);
    let b = push_bulk(
        &s,
        &kept_user,
        &[
            bulk_note(v2, u(21), 1, &[u(31)]),
            bulk_note(v3, u(22), 1, &[u(32)]),
        ],
        NOW,
    );
    assert_eq!(points(&s), HashSet::from([u(32)]));
    assert_eq!((a.skipped_tomb, b.skipped_tomb, b.applied), (1, 1, 1));
    assert_eq!(s.user_stats(&gone_user), (0, 0));
}

// The other direction: a batch newer than feed rows still in flight. The
// late rows (stamp 1) are stale against the batch (stamp 2) and change
// nothing; a point the batch keeps is not dropped.
#[test]
fn late_feed_rows_older_than_a_bulk_batch_change_nothing() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (user, vault, note, a, b, c) = (u(1), u(2), u(3), u(10), u(11), u(12));
    push_bulk(&s, &user, &[bulk_note(vault, note, 2, &[b, c])], NOW);
    let mut r = Rows::new();
    pass(&mut r, 4, user, vault, note, 1, &[a, b], &[a, b]);
    apply_all(&s, &r.out);
    assert_eq!(points(&s), HashSet::from([b, c]));
    let want: u64 = [b, c].iter().map(|p| len_of(&terms_of(p))).sum();
    assert_eq!(s.user_stats(&user), (2, want));
    // A newer edit after the batch applies as usual.
    let mut r = Rows {
        seq: 10,
        out: vec![],
    };
    pass(&mut r, 8, user, vault, note, 3, &[c], &[]);
    apply_all(&s, &r.out);
    assert_eq!(points(&s), HashSet::from([c]));
}

// A note too big for one request goes in parts at one stamp; the second
// part is a continuation, not stale, and a doc outside the keep set is
// still refused.
#[test]
fn a_bulk_note_split_across_requests_lands_whole() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (user, vault, note, a, b, x) = (u(1), u(2), u(3), u(10), u(11), u(19));
    let mut first = bulk_note(vault, note, 4, &[a, b]);
    first.docs.truncate(1);
    let mut second = bulk_note(vault, note, 4, &[a, b]);
    second.docs = vec![(b, terms_of(&b)), (x, terms_of(&x))];
    push_bulk(&s, &user, &[first], NOW);
    let got = push_bulk(&s, &user, &[second], NOW);
    assert_eq!(got.applied, 1);
    assert_eq!(points(&s), HashSet::from([a, b]));
    assert_eq!(s.notes(&user, None, 10).unwrap(), vec![(note, vault, 2)]);
}

#[test]
fn notes_lists_a_users_doc_counts_by_note_id_in_pages() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (user, other, vault) = (u(1), u(2), u(3));
    let (n1, n2) = (Uuid::from_u64_pair(1, 1), Uuid::from_u64_pair(1, 2));
    push_bulk(
        &s,
        &user,
        &[
            bulk_note(vault, n2, 1, &[u(10), u(11)]),
            bulk_note(vault, n1, 1, &[u(12)]),
        ],
        NOW,
    );
    push_bulk(&s, &other, &[bulk_note(u(4), u(5), 1, &[u(13)])], NOW);
    assert_eq!(
        s.notes(&user, None, 10).unwrap(),
        vec![(n1, vault, 1), (n2, vault, 2)]
    );
    assert_eq!(s.notes(&user, Some(n1), 10).unwrap(), vec![(n2, vault, 2)]);
    assert_eq!(s.notes(&user, None, 1).unwrap(), vec![(n1, vault, 1)]);
}

// Security F5: a re-keyed upsert (same point, other terms: a DEK rotation's
// resparse) leaves the old-key doc in its segment. Once the re-key
// settles, the shard purges, and no segment holds an old-key term.
#[test]
fn a_rekey_purges_old_key_terms_from_disk() {
    let dir = tmp();
    let s = Shard::open(dir.path()).unwrap();
    let (user, vault, note, p) = (u(1), u(2), u(3), u(10));
    let row = |xid: u64, stamp: i64, terms: Vec<u8>| Row {
        seq: xid as i64,
        xid,
        xmax: xid + 1,
        user,
        gen: 1,
        op: kwfeed::UPSERT,
        vault: Some(vault),
        note: Some(note),
        point: Some(p),
        stamp,
        terms: Some(terms),
        keep: None,
    };
    let old_dim = 0xdead_beef_u32;
    // Twenty other docs in the segment: one deleted doc of 21 is under the
    // 10% merge ratio, so only the purge takes it off the disk.
    let mut first = vec![row(1, 1, kwfeed::pack([(old_dim, 2)]))];
    for i in 0..20u64 {
        let mut r = row(1, 1, kwfeed::pack([(9, 1)]));
        r.seq = 100 + i as i64;
        r.point = Some(Uuid::from_u64_pair(77, i));
        first.push(r);
    }
    let refs: Vec<&Row> = first.iter().collect();
    s.apply(&refs, MB, NOW).unwrap();
    s.commit((1, 200), 0, NOW, TTL).unwrap();
    assert!(s.rekey_at().is_none(), "a first upsert is no re-key");
    s.apply(&[&row(2, 2, kwfeed::pack([(7, 2)]))], MB, NOW)
        .unwrap();
    s.commit((2, 2), 0, NOW, TTL).unwrap();
    assert_eq!(s.rekey_at(), Some(NOW));
    assert_eq!(points(&s).len(), 21);
    let old = crate::shard::tok(&user, old_dim).into_bytes();
    let has_old = |d: &Path| {
        segment_terms_and_orphans(d)
            .0
            .iter()
            .any(|t| t.windows(old.len()).any(|w| w == old.as_slice()))
    };
    assert!(
        has_old(dir.path()),
        "precondition: the old doc is still on disk"
    );
    assert!(s.purge(MB).unwrap());
    s.commit((2, 2), 0, NOW, TTL).unwrap();
    assert!(s.rekey_at().is_none());
    s.close_writer();
    drop(s);
    assert!(
        !has_old(dir.path()),
        "an old-key term is still in a segment"
    );
}
