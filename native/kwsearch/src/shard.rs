//! One Tantivy shard (an index holding the users with `hash(user) % 256`).
//!
//! The commit payload holds the feed cursor the shard has applied up to, its
//! tombstones and the time of its oldest unpurged delete, so a crash between
//! two shard commits replays each shard exactly from where IT stopped.
//!
//! Three kinds of doc live in a shard:
//! * chunk docs (`t`, `point`, `note`, `vault`, `user`, `ph`/`pl`, `len`, `crc`);
//! * note markers (`mnote`, ...): a note's highest applied index stamp and
//!   its full point set, needed only while ops for the note can still
//!   arrive out of order (roadmap P2 task 4a, 4g) and for `MARKER_HOLD_S`
//!   after they were applied, so a bulk batch read before the op is
//!   recognised as older (`bulk`);
//! * user stats (`suser`, `sdocs`, `stokens`): the user's live chunk count
//!   and token total, maintained on apply and read in O(1) at search time
//!   (P2 task 4). The POC scanned them per search: ~166 ms at 193k chunks,
//!   and the cache died on every commit of the shard.

use crate::row::Row;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::ops::Bound;
use std::path::Path;
use std::sync::Mutex;
use std::time::Instant;
use tantivy::collector::{DocSetCollector, TopDocs};
use tantivy::directory::MmapDirectory;
use tantivy::indexer::{LogMergePolicy, MergePolicy, NoMergePolicy};
use tantivy::query::{
    Bm25StatisticsProvider, BooleanQuery, ConstScoreQuery, Occur, Query, RangeQuery, TermQuery,
    TermSetQuery,
};
use tantivy::schema::{
    Field, IndexRecordOption, Schema, TextFieldIndexing, TextOptions, FAST, INDEXED, STRING,
};
use tantivy::tokenizer::{PreTokenizedString, Token};
use tantivy::{
    DocId, Index, IndexReader, IndexWriter, ReloadPolicy, Searcher, SegmentReader, TantivyDocument,
    Term,
};
use uuid::Uuid;

pub const SHARDS: usize = 256;

/// Merge a segment once a tenth of its docs are deleted (Tantivy's default
/// is 1.0: a deleted doc's bytes could stay on disk forever, security F1).
pub const DEL_DOCS_RATIO: f32 = 0.1;

/// A bulk batch (backfill, reconcile) read longer ago than this is refused:
/// the per-note markers that order it against live feed ops are only kept
/// this long (roadmap P2 task 5).
pub const BULK_MAX_AGE_S: u64 = 3_600;

/// How long a note marker outlives its apply, past the feed's own bound
/// (the snapshot xmax): the bulk age plus 10 minutes of clock skew between
/// the app and this node. A bulk batch is accepted only while every note
/// op applied after its read still has its marker here.
pub const MARKER_HOLD_S: u64 = BULK_MAX_AGE_S + 600;

/// Re-keyed upserts (same point, other terms: a DEK rotation or a tokenizer
/// change) purge the shard once none has arrived for this long (F5).
pub const REKEY_SETTLE_S: u64 = 600;

/// FNV-1a 64. Shard placement must never change across Rust releases
/// (std's DefaultHasher may).
pub fn fnv(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325u64, |h, b| {
        (h ^ *b as u64).wrapping_mul(0x0100_0000_01b3)
    })
}

pub fn shard_of(user: &Uuid) -> usize {
    (fnv(user.as_bytes()) % SHARDS as u64) as usize
}

/// A term token is the user's id + the HMAC dim. HMAC dims are only 32 bits,
/// so in a shard holding thousands of users two users DO share dims; the
/// prefix keeps posting lists and document frequencies per user (task 4c).
pub fn tok(user: &Uuid, term: u32) -> String {
    format!("{}{:08x}", user.simple(), term)
}

pub fn id(u: &Uuid) -> String {
    u.simple().to_string()
}

#[derive(Clone, Copy)]
pub struct F {
    pub t: Field,
    pub point: Field,
    pub note: Field,
    pub vault: Field,
    pub user: Field,
    pub ph: Field,
    pub pl: Field,
    pub len: Field,
    pub crc: Field,
    pub nh: Field,
    pub nl: Field,
    pub vh: Field,
    pub vl: Field,
    pub mnote: Field,
    pub muser: Field,
    pub mvault: Field,
    pub stamp: Field,
    pub mhaskeep: Field,
    pub mkeep: Field,
    pub mexp: Field,
    pub mat: Field,
    pub suser: Field,
    pub sdocs: Field,
    pub stokens: Field,
}

pub fn schema() -> (Schema, F) {
    let mut s = Schema::builder();
    let freqs = TextOptions::default().set_indexing_options(
        TextFieldIndexing::default()
            .set_tokenizer("raw")
            .set_index_option(IndexRecordOption::WithFreqs),
    );
    let f = F {
        t: s.add_text_field("t", freqs),
        point: s.add_text_field("point", STRING),
        note: s.add_text_field("note", STRING),
        vault: s.add_text_field("vault", STRING),
        user: s.add_text_field("user", STRING),
        ph: s.add_u64_field("ph", FAST),
        pl: s.add_u64_field("pl", FAST),
        len: s.add_u64_field("len", FAST),
        crc: s.add_u64_field("crc", FAST),
        nh: s.add_u64_field("nh", FAST),
        nl: s.add_u64_field("nl", FAST),
        vh: s.add_u64_field("vh", FAST),
        vl: s.add_u64_field("vl", FAST),
        mnote: s.add_text_field("mnote", STRING),
        muser: s.add_text_field("muser", STRING),
        mvault: s.add_text_field("mvault", STRING),
        stamp: s.add_u64_field("stamp", FAST),
        mhaskeep: s.add_u64_field("mhaskeep", FAST),
        mkeep: s.add_text_field("mkeep", STRING),
        mexp: s.add_u64_field("mexp", INDEXED | FAST),
        mat: s.add_u64_field("mat", INDEXED | FAST),
        suser: s.add_text_field("suser", STRING),
        sdocs: s.add_u64_field("sdocs", FAST),
        stokens: s.add_u64_field("stokens", FAST),
    };
    (s.build(), f)
}

/// Commit payload.
#[derive(Serialize, Deserialize, Default, Clone, Debug)]
pub struct Meta {
    /// (xid, seq) of the last feed row this shard applied (or skipped as not
    /// its own) when it committed.
    pub cursor: (u64, i64),
    /// Deleted users and vaults -> unix seconds of the delete. A late upsert
    /// (higher xid, committed before the delete) is dropped against them.
    /// Each expires after the tombstone TTL (>= snapshot retention, F12).
    pub tomb_users: BTreeMap<Uuid, u64>,
    pub tomb_vaults: BTreeMap<Uuid, u64>,
    /// Unix seconds of the oldest delete not yet purged from disk (F1).
    #[serde(default)]
    pub first_delete_at: Option<u64>,
    /// Unix seconds of the last re-keyed upsert not yet purged (F5).
    #[serde(default)]
    pub rekey_at: Option<u64>,
}

pub struct Writer {
    pub w: IndexWriter,
    pub used: Instant,
}

/// A chunk doc added since the last commit (not visible to the searcher).
struct Pending {
    user: Uuid,
    note: Uuid,
    vault: Uuid,
    len: u64,
}

pub struct State {
    pub writer: Option<Writer>,
    pub meta: Meta,
    pub dirty: bool,
    markers: HashMap<Uuid, Marker>,
    pending: HashMap<Uuid, Pending>,
    /// Committed (searcher-visible) chunk docs deleted this round.
    gone: HashSet<Uuid>,
    /// Per-user (docs, tokens) change this round, folded into the stats doc
    /// on commit.
    delta: HashMap<Uuid, (i64, i64)>,
    /// A delete_user / delete_vault ran: purge right after the commit (F1).
    pub purge_now: bool,
    /// Unix seconds of the apply in progress (stamped on markers).
    now: u64,
}

/// A note's highest applied index stamp and, if the op that set it named
/// one, the note's full point set at that stamp (`committed`: read it from
/// the index; else `keep` holds it).
pub struct Marker {
    stamp: u64,
    keep: Option<HashSet<Uuid>>,
    committed: bool,
}

/// One note of a bulk batch: its full point set at `stamp` (taken under the
/// note's row lock when the batch read it) and the docs of those points.
#[derive(Debug, Clone)]
pub struct BulkNote {
    pub vault: Uuid,
    pub note: Uuid,
    pub stamp: i64,
    /// xmax of the snapshot the batch was read under (marker expiry, 4g).
    pub xmax: u64,
    pub keep: Vec<Uuid>,
    pub docs: Vec<(Uuid, Vec<u8>)>,
}

pub struct Shard {
    pub index: Index,
    pub reader: IndexReader,
    pub f: F,
    pub state: Mutex<State>,
}

#[derive(Default, Debug, PartialEq)]
pub struct Applied {
    pub applied: u64,
    /// Rows that cannot be applied (ragged terms, a note op without its note
    /// or vault): skipped and counted, never a panic, so one bad row cannot
    /// crash-loop the service for every tenant.
    pub skipped_malformed: u64,
    pub filled_stale: u64,
    pub skipped_stale: u64,
    pub skipped_tomb: u64,
}

impl Applied {
    /// No ids or terms in the log line: the feed seq is enough to find it.
    fn malformed(&mut self, r: &Row) {
        self.skipped_malformed += 1;
        eprintln!("feed row skipped: malformed (seq {})", r.seq);
    }
}

enum Scope<'a> {
    Point(Uuid),
    Note(Uuid, Option<&'a HashSet<Uuid>>),
    Vault(Uuid),
}

fn must(f: Field, v: &Uuid) -> (Occur, Box<dyn Query>) {
    (
        Occur::Must,
        Box::new(TermQuery::new(
            Term::from_field_text(f, &id(v)),
            IndexRecordOption::Basic,
        )),
    )
}

impl Shard {
    pub fn open(dir: &Path) -> tantivy::Result<Shard> {
        std::fs::create_dir_all(dir)?;
        let (schema, f) = schema();
        let index = Index::open_or_create(MmapDirectory::open(dir)?, schema)?;
        // No payload: a shard never committed. An unreadable one fails the
        // open: defaulting would reset the cursor and drop every tombstone,
        // so deleted users and vaults could come back (review #11).
        let meta = match index.load_metas()?.payload {
            None => Meta::default(),
            Some(p) => serde_json::from_str(&p).map_err(|e| {
                tantivy::TantivyError::InvalidArgument(format!(
                    "shard {dir:?}: unreadable commit payload: {e}"
                ))
            })?,
        };
        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .try_into()?;
        Ok(Shard {
            index,
            reader,
            f,
            state: Mutex::new(State {
                writer: None,
                meta,
                dirty: false,
                markers: HashMap::new(),
                pending: HashMap::new(),
                gone: HashSet::new(),
                delta: HashMap::new(),
                purge_now: false,
                now: 0,
            }),
        })
    }

    pub fn cursor(&self) -> (u64, i64) {
        self.state.lock().unwrap().meta.cursor
    }

    pub fn first_delete_at(&self) -> Option<u64> {
        self.state.lock().unwrap().meta.first_delete_at
    }

    pub fn rekey_at(&self) -> Option<u64> {
        self.state.lock().unwrap().meta.rekey_at
    }

    fn ensure_writer(&self, st: &mut State, writer_mb: usize) -> tantivy::Result<()> {
        if st.writer.is_none() {
            let w: IndexWriter = self.index.writer_with_num_threads(1, writer_mb << 20)?;
            // No background merges: `compact` runs them on a clean shard
            // right after a commit, on this thread. A background merge racing
            // the next round's deletes brought deleted docs back (property
            // test, seed 343 of 3000).
            w.set_merge_policy(Box::new(NoMergePolicy));
            // A kill -9 leaves files the dead writer created but never
            // committed (e.g. `<segment>.<opstamp>.del`). The new writer
            // restarts from the committed opstamp, reuses those names and
            // its commit fails with FileAlreadyExists. Collect them first.
            w.garbage_collect_files().wait()?;
            st.writer = Some(Writer {
                w,
                used: Instant::now(),
            });
        }
        Ok(())
    }

    /// Applies rows in (xid, seq) order. Rows at or below the shard's
    /// committed cursor were applied before a crash and are skipped.
    pub fn apply(&self, rows: &[&Row], writer_mb: usize, now: u64) -> tantivy::Result<Applied> {
        let mut guard = self.state.lock().unwrap();
        let st = &mut *guard;
        st.now = now;
        let mut out = Applied::default();
        for r in rows {
            if (r.xid, r.seq) <= st.meta.cursor {
                continue;
            }
            if !(kwfeed::UPSERT..=kwfeed::DELETE_NOTE_EXCEPT).contains(&r.op) {
                out.skipped_stale += 1; // unknown op code from a newer writer
                continue;
            }
            // A deleted user's docs and stats are gone: every later row for
            // them is a no-op (a vault delete still leaves its tombstone).
            if st.meta.tomb_users.contains_key(&r.user) {
                if let (kwfeed::DELETE_VAULT, Some(v)) = (r.op, r.vault) {
                    st.meta.tomb_vaults.insert(v, now);
                }
                out.skipped_tomb += 1;
                continue;
            }
            self.ensure_writer(st, writer_mb)?;
            let tomb = r
                .vault
                .is_some_and(|v| st.meta.tomb_vaults.contains_key(&v));
            match r.op {
                kwfeed::DELETE_USER => {
                    self.drop_user(st, &r.user)?;
                    st.meta.tomb_users.insert(r.user, now);
                    st.purge_now = true;
                }
                kwfeed::DELETE_VAULT => {
                    let Some(v) = r.vault else {
                        out.malformed(r);
                        continue;
                    };
                    self.drop_vault(st, &r.user, &v)?;
                    st.meta.tomb_vaults.insert(v, now);
                    st.purge_now = true;
                }
                _ if tomb => {
                    out.skipped_tomb += 1;
                    continue;
                }
                kwfeed::DELETE_POINTS if r.note.is_none() => {
                    // Bare point delete (tenant known, note not): no marker.
                    if let Some(p) = r.point {
                        self.remove(st, &r.user, Scope::Point(p))?;
                    }
                }
                op => {
                    let (Some(note), Some(vault)) = (r.note, r.vault) else {
                        out.malformed(r);
                        continue;
                    };
                    if op == kwfeed::UPSERT
                        && (r.point.is_none()
                            || kwfeed::unpack(r.terms.as_deref().unwrap_or_default()).is_none())
                    {
                        out.malformed(r);
                        continue;
                    }
                    if !self.note_op(st, r, op, note, vault, &mut out)? {
                        continue;
                    }
                }
            }
            out.applied += 1;
            st.dirty = true;
            if r.op != kwfeed::UPSERT && st.meta.first_delete_at.is_none() {
                st.meta.first_delete_at = Some(now);
            }
        }
        Ok(out)
    }

    /// A note-scoped op. Returns false when it was skipped as stale.
    fn note_op(
        &self,
        st: &mut State,
        r: &Row,
        op: i16,
        note: Uuid,
        vault: Uuid,
        out: &mut Applied,
    ) -> tantivy::Result<bool> {
        let stamp = r.stamp.max(0) as u64;
        if let std::collections::hash_map::Entry::Vacant(e) = st.markers.entry(note) {
            e.insert(self.committed_marker(&note));
        }
        let have = st.markers[&note].stamp;
        if stamp < have {
            // Stale: a newer pass for this note was applied first (lower
            // xid, later commit). Its keep set says which points survive;
            // this pass's upsert of a kept point that is not indexed yet is
            // the only content for it. Point ids are content-derived, so an
            // indexed point already holds this content. Everything else is
            // a no-op.
            let p = r.point.filter(|_| op == kwfeed::UPSERT);
            let fill = p
                .is_some_and(|p| self.kept(&st.markers[&note], &note, &p) && !self.indexed(st, &p));
            if !fill {
                out.skipped_stale += 1;
                return Ok(false);
            }
            let p = p.unwrap();
            self.remove(st, &r.user, Scope::Point(p))?;
            self.add(st, r, &p, vault)?;
            out.filled_stale += 1;
            return Ok(true);
        }
        let keep: Option<Vec<Uuid>> = match op {
            kwfeed::DELETE_NOTE_EXCEPT => Some(r.keep.clone().unwrap_or_default()),
            kwfeed::DELETE_NOTE => Some(Vec::new()),
            _ => None,
        };
        if stamp > have || keep.is_some() {
            self.set_marker(st, r, note, vault, stamp, keep.as_deref())?;
        }
        match op {
            kwfeed::UPSERT => {
                let Some(p) = r.point else { return Ok(false) };
                // A pass's upserts are a subset of its own keep set. An upsert
                // at the marker's stamp naming a point outside it came from a
                // keep set read too early (review #1): drop it rather than
                // bring back a point the note no longer has.
                let m = &st.markers[&note];
                if stamp == m.stamp && (m.keep.is_some() || m.committed) && !self.kept(m, &note, &p)
                {
                    out.skipped_stale += 1;
                    return Ok(false);
                }
                self.upsert_doc(st, r, &p, vault)?;
            }
            kwfeed::DELETE_POINTS => {
                let Some(p) = r.point else { return Ok(false) };
                self.remove(st, &r.user, Scope::Point(p))?;
                if let Some(k) = st.markers.get_mut(&note).and_then(|m| m.keep.as_mut()) {
                    k.remove(&p);
                }
            }
            kwfeed::DELETE_NOTE => self.remove(st, &r.user, Scope::Note(note, None))?,
            kwfeed::DELETE_NOTE_EXCEPT => {
                let keep: HashSet<Uuid> = r.keep.iter().flatten().copied().collect();
                self.remove(st, &r.user, Scope::Note(note, Some(&keep)))?;
            }
            _ => unreachable!("op checked in apply"),
        }
        Ok(true)
    }

    /// A fresh upsert: the point's doc is replaced. Same point, other terms
    /// means the key or the tokenizer changed (point ids follow content);
    /// the old doc's bytes stay in its segment until a merge, so the shard
    /// purges once the re-key settles (F5).
    fn upsert_doc(&self, st: &mut State, r: &Row, p: &Uuid, vault: Uuid) -> tantivy::Result<()> {
        let new_crc = fnv(r.terms.as_deref().unwrap_or_default());
        if self.committed_crc(&r.user, p).is_some_and(|c| c != new_crc) {
            st.meta.rekey_at = Some(st.now);
        }
        self.remove(st, &r.user, Scope::Point(*p))?;
        self.add(st, r, p, vault)
    }

    fn set_marker(
        &self,
        st: &mut State,
        r: &Row,
        note: Uuid,
        vault: Uuid,
        stamp: u64,
        keep: Option<&[Uuid]>,
    ) -> tantivy::Result<()> {
        let f = self.f;
        let w = &st.writer.as_ref().unwrap().w;
        w.delete_query(Box::new(BooleanQuery::new(vec![
            must(f.mnote, &note),
            must(f.muser, &r.user),
        ])))?;
        let mut m = TantivyDocument::default();
        m.add_text(f.mnote, id(&note));
        m.add_text(f.muser, id(&r.user));
        m.add_text(f.mvault, id(&vault));
        m.add_u64(f.stamp, stamp);
        m.add_u64(f.mhaskeep, keep.is_some() as u64);
        // Expires once every row with an xid below the xmax of the snapshot
        // this row was read in has been applied: a stale pass for this note
        // committed before this one, so its xid is below that xmax.
        m.add_u64(f.mexp, r.xmax);
        m.add_u64(f.mat, st.now);
        for p in keep.iter().copied().flatten() {
            m.add_text(f.mkeep, id(p));
        }
        w.add_document(m)?;
        let keep = keep.map(|k| k.iter().copied().collect());
        st.markers.insert(
            note,
            Marker {
                stamp,
                keep,
                committed: false,
            },
        );
        Ok(())
    }

    fn add(&self, st: &mut State, r: &Row, p: &Uuid, vault: Uuid) -> tantivy::Result<()> {
        let doc = self.doc(r, p, vault)?;
        let len = doc.1;
        st.writer.as_ref().unwrap().w.add_document(doc.0)?;
        st.pending.insert(
            *p,
            Pending {
                user: r.user,
                note: r.note.unwrap(),
                vault,
                len,
            },
        );
        let d = st.delta.entry(r.user).or_default();
        d.0 += 1;
        d.1 += len as i64;
        Ok(())
    }

    /// Deletes the user's chunk docs in `scope`, keeping the user's stats
    /// exact: every removed doc's length comes off its user's total. The
    /// delete is always scoped by user as well (F7): a row for user B that
    /// names user A's vault, note or point removes nothing of A's.
    fn remove(&self, st: &mut State, user: &Uuid, scope: Scope) -> tantivy::Result<()> {
        let f = self.f;
        let mut q = vec![must(f.user, user)];
        let mut keep_terms = None;
        match &scope {
            Scope::Point(p) => q.push(must(f.point, p)),
            Scope::Note(n, keep) => {
                q.push(must(f.note, n));
                keep_terms = keep.map(|k| {
                    k.iter()
                        .map(|p| Term::from_field_text(f.point, &id(p)))
                        .collect::<Vec<_>>()
                });
            }
            Scope::Vault(v) => q.push(must(f.vault, v)),
        }
        if let Some(k) = keep_terms {
            q.push((Occur::MustNot, Box::new(TermSetQuery::new(k))));
        }
        let q = BooleanQuery::new(q);
        let s = self.reader.searcher();
        let mut freed = (0i64, 0i64);
        for a in s.search(&q, &DocSetCollector)? {
            let ff = s.segment_reader(a.segment_ord).fast_fields();
            let hi = ff.u64("ph")?.first(a.doc_id).unwrap_or(0);
            let lo = ff.u64("pl")?.first(a.doc_id).unwrap_or(0);
            if st.gone.insert(Uuid::from_u64_pair(hi, lo)) {
                freed.0 += 1;
                freed.1 += ff.u64("len")?.first(a.doc_id).unwrap_or(0) as i64;
            }
        }
        st.pending.retain(|p, d| {
            let hit = d.user == *user
                && match &scope {
                    Scope::Point(x) => p == x,
                    Scope::Note(n, keep) => d.note == *n && !keep.is_some_and(|k| k.contains(p)),
                    Scope::Vault(v) => d.vault == *v,
                };
            if hit {
                freed.0 += 1;
                freed.1 += d.len as i64;
            }
            !hit
        });
        let d = st.delta.entry(*user).or_default();
        d.0 -= freed.0;
        d.1 -= freed.1;
        st.writer.as_ref().unwrap().w.delete_query(Box::new(q))?;
        Ok(())
    }

    fn drop_user(&self, st: &mut State, user: &Uuid) -> tantivy::Result<()> {
        let f = self.f;
        let w = &st.writer.as_ref().unwrap().w;
        for field in [f.user, f.muser, f.suser] {
            w.delete_term(Term::from_field_text(field, &id(user)));
        }
        st.pending.retain(|_, d| d.user != *user);
        // In-memory markers stay: clearing them all would make the next op
        // of ANOTHER note in this shard read its committed (older) marker and
        // apply a stale pass as fresh. The deleted user's are never read again
        // (every later row for the user or vault is tombstoned).
        st.delta.remove(user);
        Ok(())
    }

    fn drop_vault(&self, st: &mut State, user: &Uuid, vault: &Uuid) -> tantivy::Result<()> {
        self.remove(st, user, Scope::Vault(*vault))?;
        let f = self.f;
        let q = BooleanQuery::new(vec![must(f.mvault, vault), must(f.muser, user)]);
        st.writer.as_ref().unwrap().w.delete_query(Box::new(q))?;
        Ok(())
    }

    fn doc(&self, r: &Row, p: &Uuid, vault: Uuid) -> tantivy::Result<(TantivyDocument, u64)> {
        let f = self.f;
        let raw = r.terms.as_deref().unwrap_or_default();
        let pairs = kwfeed::unpack(raw)
            .ok_or_else(|| tantivy::TantivyError::InvalidArgument("ragged terms".into()))?;
        let mut tokens = Vec::new();
        for (term, n) in pairs {
            let text = tok(&r.user, term);
            for _ in 0..n {
                tokens.push(Token {
                    position: tokens.len(),
                    text: text.clone(),
                    ..Token::default()
                });
            }
        }
        let len = tokens.len() as u64;
        let mut d = TantivyDocument::default();
        d.add_pre_tokenized_text(
            f.t,
            PreTokenizedString {
                text: String::new(),
                tokens,
            },
        );
        d.add_text(f.point, id(p));
        d.add_text(f.note, id(&r.note.unwrap()));
        d.add_text(f.vault, id(&vault));
        d.add_text(f.user, id(&r.user));
        let (hi, lo) = p.as_u64_pair();
        d.add_u64(f.ph, hi);
        d.add_u64(f.pl, lo);
        d.add_u64(f.len, len);
        d.add_u64(f.crc, fnv(raw));
        let (nh, nl) = r.note.unwrap().as_u64_pair();
        d.add_u64(f.nh, nh);
        d.add_u64(f.nl, nl);
        let (vh, vl) = vault.as_u64_pair();
        d.add_u64(f.vh, vh);
        d.add_u64(f.vl, vl);
        Ok((d, len))
    }

    /// Commits pending ops with `cursor`, folds the round's stats changes
    /// into each touched user's stats doc, expires markers every row of
    /// which has been applied (`watermark`: every feed row with a lower xid
    /// is applied) once they are also older than `MARKER_HOLD_S`, and
    /// tombstones older than `tomb_ttl_s`, then reloads.
    pub fn commit(
        &self,
        cursor: (u64, i64),
        watermark: u64,
        now: u64,
        tomb_ttl_s: u64,
    ) -> tantivy::Result<bool> {
        let mut guard = self.state.lock().unwrap();
        let st = &mut *guard;
        st.meta.cursor = cursor;
        if !st.dirty {
            return Ok(false);
        }
        let f = self.f;
        let s = self.reader.searcher();
        let w = &st.writer.as_ref().expect("dirty shard without writer").w;
        for (user, (dn, dt)) in st.delta.drain() {
            if dn == 0 && dt == 0 {
                continue;
            }
            let (n, t) = stats_of(&s, f, &user);
            w.delete_term(Term::from_field_text(f.suser, &id(&user)));
            let mut d = TantivyDocument::default();
            d.add_text(f.suser, id(&user));
            d.add_u64(f.sdocs, (n as i64 + dn).max(0) as u64);
            d.add_u64(f.stokens, (t as i64 + dt).max(0) as u64);
            w.add_document(d)?;
        }
        let held = now.saturating_sub(MARKER_HOLD_S);
        w.delete_query(Box::new(BooleanQuery::new(vec![
            (
                Occur::Must,
                Box::new(RangeQuery::new(
                    Bound::Unbounded,
                    Bound::Included(Term::from_field_u64(f.mexp, watermark)),
                )) as Box<dyn Query>,
            ),
            (
                Occur::Must,
                Box::new(RangeQuery::new(
                    Bound::Unbounded,
                    Bound::Included(Term::from_field_u64(f.mat, held)),
                )),
            ),
        ])))?;
        let cutoff = now.saturating_sub(tomb_ttl_s);
        st.meta.tomb_users.retain(|_, at| *at > cutoff);
        st.meta.tomb_vaults.retain(|_, at| *at > cutoff);
        let payload = serde_json::to_string(&st.meta).unwrap();
        let w = st.writer.as_mut().unwrap();
        let mut prepared = w.w.prepare_commit()?;
        prepared.set_payload(&payload);
        prepared.commit()?;
        w.used = Instant::now();
        st.dirty = false;
        st.markers.clear();
        st.pending.clear();
        st.gone.clear();
        drop(guard);
        self.reader.reload()?;
        self.compact()?;
        Ok(true)
    }

    /// Log merges (Tantivy's default shape) plus any segment with a tenth
    /// of its docs deleted (F1), run synchronously on a clean shard.
    fn compact(&self) -> tantivy::Result<()> {
        let mut mp = LogMergePolicy::default();
        mp.set_del_docs_ratio_before_merge(DEL_DOCS_RATIO);
        let candidates = mp.compute_merge_candidates(&self.index.searchable_segment_metas()?);
        if candidates.is_empty() {
            return Ok(());
        }
        let mut guard = self.state.lock().unwrap();
        if guard.dirty {
            return Ok(());
        }
        let w = &mut guard
            .writer
            .as_mut()
            .expect("committed shard without writer")
            .w;
        for c in candidates {
            w.merge(&c.0).wait()?;
        }
        drop(guard);
        self.reader.reload()?;
        Ok(())
    }

    /// Physically drops deleted docs: merges every segment holding deletes
    /// into a new one, then removes the old files (security F1). Run right
    /// after a delete_user / delete_vault and on a schedule. Returns false
    /// when there was nothing to purge or a background merge holds one of
    /// the segments (try again next round). Only on a clean shard.
    pub fn purge(&self, writer_mb: usize) -> tantivy::Result<bool> {
        let mut guard = self.state.lock().unwrap();
        let st = &mut *guard;
        if st.dirty {
            return Ok(false);
        }
        st.purge_now = false;
        // Let any merge the policy already started finish first: merging a
        // segment that is in a merge fails. Then merge what still holds deletes.
        if let Some(w) = st.writer.take() {
            w.w.wait_merging_threads()?;
            self.reader.reload()?;
        }
        let ids: Vec<_> = self
            .reader
            .searcher()
            .segment_readers()
            .iter()
            .filter(|s| s.num_deleted_docs() > 0)
            .map(|s| s.segment_id())
            .collect();
        self.ensure_writer(st, writer_mb)?;
        st.meta.rekey_at = None;
        if ids.is_empty() {
            st.meta.first_delete_at = None;
            st.dirty = true;
            return Ok(true);
        }
        let w = &mut st.writer.as_mut().unwrap().w;
        w.merge(&ids).wait()?;
        // Persist "no unpurged deletes" with the next commit, and let the
        // reader drop the old segments before their files are collected.
        st.meta.first_delete_at = None;
        st.dirty = true;
        drop(guard);
        self.reader.reload()?;
        let g = self.state.lock().unwrap();
        g.writer
            .as_ref()
            .unwrap()
            .w
            .garbage_collect_files()
            .wait()?;
        Ok(true)
    }

    /// Closes the writer (flushes its arena, joins its threads). Only on a
    /// clean shard, so no uncommitted op is lost.
    pub fn close_writer(&self) -> bool {
        let mut st = self.state.lock().unwrap();
        if st.dirty {
            return false;
        }
        match st.writer.take() {
            Some(w) => {
                let _ = w.w.wait_merging_threads();
                true
            }
            None => false,
        }
    }

    /// Test stand-in for kill -9: drops every uncommitted op and lets any
    /// background merge of COMMITTED segments finish, so no thread of the
    /// "dead" writer outlives it (a real crash kills those threads; an
    /// in-process drop would let one save its meta over the next writer's).
    #[cfg(test)]
    pub fn crash(&self) {
        let mut st = self.state.lock().unwrap();
        if let Some(mut w) = st.writer.take() {
            w.w.rollback().unwrap();
            w.w.wait_merging_threads().unwrap();
        }
    }

    /// Deletes from the durable deletion log, applied on boot before the
    /// service serves (a restored snapshot must never undo a later delete).
    /// Hard deletes with no marker and no cursor move: the feed, if it still
    /// holds the row, replays it with its stamp afterwards.
    pub fn apply_deletion(
        &self,
        op: i16,
        user: &Uuid,
        vault: Option<Uuid>,
        note: Option<Uuid>,
        writer_mb: usize,
        now: u64,
    ) -> tantivy::Result<bool> {
        let mut guard = self.state.lock().unwrap();
        let st = &mut *guard;
        if st.meta.tomb_users.contains_key(user) {
            return Ok(false);
        }
        self.ensure_writer(st, writer_mb)?;
        match (op, vault, note) {
            (kwfeed::DELETE_USER, _, _) => {
                self.drop_user(st, user)?;
                st.meta.tomb_users.insert(*user, now);
            }
            (kwfeed::DELETE_VAULT, Some(v), _) => {
                self.drop_vault(st, user, &v)?;
                st.meta.tomb_vaults.insert(v, now);
            }
            (kwfeed::DELETE_NOTE, _, Some(n)) => self.remove(st, user, Scope::Note(n, None))?,
            _ => return Ok(false),
        }
        st.dirty = true;
        st.purge_now = true;
        st.meta.first_delete_at.get_or_insert(now);
        Ok(true)
    }

    /// Applies one bulk batch of `user` (backfill, reconcile; roadmap P2
    /// task 5). Each note is a whole pass at its own stamp: the note's full
    /// point set, then its docs. The feed's ordering does not cover a batch,
    /// so each note is checked here instead:
    /// * a tombstoned user or vault: dropped (a batch read before the delete);
    /// * a note whose applied stamp (its marker, kept `MARKER_HOLD_S` after
    ///   apply) is above the batch's: dropped, so a batch read before an
    ///   edit or a delete never brings back older content.
    ///
    /// The batch's age bound (`BULK_MAX_AGE_S`, checked by the caller) is
    /// what makes a missing marker safe: every op applied after the batch was
    /// read is younger than the hold. Commit with `commit_here`.
    pub fn bulk(
        &self,
        user: &Uuid,
        gen: i16,
        notes: &[BulkNote],
        writer_mb: usize,
        now: u64,
    ) -> tantivy::Result<Applied> {
        let mut guard = self.state.lock().unwrap();
        let st = &mut *guard;
        st.now = now;
        let mut out = Applied::default();
        for n in notes {
            if st.meta.tomb_users.contains_key(user) || st.meta.tomb_vaults.contains_key(&n.vault) {
                out.skipped_tomb += 1;
                continue;
            }
            if n.stamp <= 0 || n.docs.iter().any(|d| kwfeed::unpack(&d.1).is_none()) {
                out.skipped_malformed += 1;
                continue;
            }
            if let std::collections::hash_map::Entry::Vacant(e) = st.markers.entry(n.note) {
                e.insert(self.committed_marker(&n.note));
            }
            // Stamps are unique per note op, so an equal one is this same
            // batch note again: the rest of a note too big for one request,
            // or a retry. Its point set is already applied; its docs still
            // go through the marker's keep check.
            let have = st.markers[&n.note].stamp;
            if (n.stamp as u64) < have {
                out.skipped_stale += 1;
                continue;
            }
            self.ensure_writer(st, writer_mb)?;
            let row = Row {
                xmax: n.xmax,
                user: *user,
                gen,
                op: kwfeed::UPSERT,
                vault: Some(n.vault),
                note: Some(n.note),
                stamp: n.stamp,
                ..Row::default()
            };
            if n.stamp as u64 > have {
                // The note now has exactly `keep`, at this stamp.
                let keep: HashSet<Uuid> = n.keep.iter().copied().collect();
                self.set_marker(st, &row, n.note, n.vault, n.stamp as u64, Some(&n.keep))?;
                self.remove(st, user, Scope::Note(n.note, Some(&keep)))?;
            }
            for (p, terms) in &n.docs {
                // Only points of the note's set at this stamp.
                if !self.kept(&st.markers[&n.note], &n.note, p) {
                    out.skipped_stale += 1;
                    continue;
                }
                let r = Row {
                    point: Some(*p),
                    terms: Some(terms.clone()),
                    ..row.clone()
                };
                self.upsert_doc(st, &r, p, n.vault)?;
            }
            out.applied += 1;
            st.dirty = true;
            st.meta.first_delete_at.get_or_insert(now);
        }
        Ok(out)
    }

    /// Commits at the shard's own cursor (a bulk batch moves no cursor).
    pub fn commit_here(&self, now: u64, tomb_ttl_s: u64) -> tantivy::Result<bool> {
        let c = self.cursor();
        self.commit(c, 0, now, tomb_ttl_s)
    }

    /// The crc of `user`'s committed doc for point `p`, if indexed.
    fn committed_crc(&self, user: &Uuid, p: &Uuid) -> Option<u64> {
        let f = self.f;
        let s = self.reader.searcher();
        let q = BooleanQuery::new(vec![must(f.user, user), must(f.point, p)]);
        let a = s.search(&q, &DocSetCollector).ok()?.into_iter().next()?;
        s.segment_reader(a.segment_ord)
            .fast_fields()
            .u64("crc")
            .ok()?
            .first(a.doc_id)
    }

    /// `user`'s committed chunk docs per note as (note, vault, count), notes
    /// after `after` in id order, at most `limit` (the reconcile's drift
    /// check and orphan pass). One pass over the user's docs (fast fields).
    pub fn notes(
        &self,
        user: &Uuid,
        after: Option<Uuid>,
        limit: usize,
    ) -> tantivy::Result<Vec<(Uuid, Uuid, u64)>> {
        let mut counts: BTreeMap<Uuid, (Uuid, u64)> = BTreeMap::new();
        let s = self.reader.searcher();
        let mut err = None;
        for_each_doc(
            &s,
            &Term::from_field_text(self.f.user, &id(user)),
            |seg, doc| {
                let ff = seg.fast_fields();
                let col = |name: &str| ff.u64(name).map(|c| c.first(doc));
                match (col("nh"), col("nl"), col("vh"), col("vl")) {
                    (Ok(Some(nh)), Ok(Some(nl)), Ok(Some(vh)), Ok(Some(vl))) => {
                        let e = counts
                            .entry(Uuid::from_u64_pair(nh, nl))
                            .or_insert((Uuid::from_u64_pair(vh, vl), 0));
                        e.1 += 1;
                    }
                    (Err(e), ..) | (_, Err(e), ..) | (.., Err(e), _) | (.., Err(e)) => {
                        err = Some(e)
                    }
                    _ => {}
                }
            },
        );
        if let Some(e) = err {
            return Err(e);
        }
        Ok(counts
            .into_iter()
            .filter(|(n, _)| after.is_none_or(|a| *n > a))
            .take(limit)
            .map(|(n, (v, c))| (n, v, c))
            .collect())
    }

    fn committed_marker(&self, note: &Uuid) -> Marker {
        let s = self.reader.searcher();
        let mut m = Marker {
            stamp: 0,
            keep: None,
            committed: false,
        };
        for_each_doc(
            &s,
            &Term::from_field_text(self.f.mnote, &id(note)),
            |seg, doc| {
                let ff = seg.fast_fields();
                m.stamp = m
                    .stamp
                    .max(ff.u64("stamp").unwrap().first(doc).unwrap_or(0));
                m.committed = ff.u64("mhaskeep").unwrap().first(doc) == Some(1);
            },
        );
        m
    }

    /// Is `p` in the note's point set as of its marker?
    fn kept(&self, m: &Marker, note: &Uuid, p: &Uuid) -> bool {
        if let Some(k) = &m.keep {
            return k.contains(p);
        }
        if !m.committed {
            return false;
        }
        let q = BooleanQuery::new(vec![must(self.f.mnote, note), must(self.f.mkeep, p)]);
        self.reader
            .searcher()
            .search(&q, &tantivy::collector::Count)
            .unwrap_or(0)
            > 0
    }

    fn indexed(&self, st: &State, p: &Uuid) -> bool {
        if st.pending.contains_key(p) {
            return true;
        }
        if st.gone.contains(p) {
            return false;
        }
        let mut any = false;
        for_each_doc(
            &self.reader.searcher(),
            &Term::from_field_text(self.f.point, &id(p)),
            |_, _| any = true,
        );
        any
    }

    /// Committed (docs, tokens) of a user: one term lookup.
    #[cfg(any(test, feature = "harness"))]
    pub fn user_stats(&self, user: &Uuid) -> (u64, u64) {
        stats_of(&self.reader.searcher(), self.f, user)
    }

    pub fn search(
        &self,
        user: &Uuid,
        vaults: &[Uuid],
        terms: &[u32],
        include: Option<&[Uuid]>,
        exclude: &[Uuid],
        limit: usize,
    ) -> tantivy::Result<Vec<(Uuid, f32)>> {
        let f = self.f;
        let s = self.reader.searcher();
        let mut terms = terms.to_vec();
        terms.sort_unstable();
        terms.dedup();
        let should: Vec<(Occur, Box<dyn Query>)> = terms
            .iter()
            .map(|t| {
                let q: Box<dyn Query> = Box::new(TermQuery::new(
                    Term::from_field_text(f.t, &tok(user, *t)),
                    IndexRecordOption::WithFreqs,
                ));
                (Occur::Should, q)
            })
            .collect();
        let set = |field: Field, ids: &[Uuid]| -> Box<dyn Query> {
            Box::new(TermSetQuery::new(
                ids.iter().map(|u| Term::from_field_text(field, &id(u))),
            ))
        };
        let zero = |q: Box<dyn Query>| -> Box<dyn Query> { Box::new(ConstScoreQuery::new(q, 0.0)) };
        // The user-prefixed terms already scope the search to one user; the
        // zero-score user clause is a second guard if that prefix ever changes.
        let user_clause: Box<dyn Query> = Box::new(TermQuery::new(
            Term::from_field_text(f.user, &id(user)),
            IndexRecordOption::Basic,
        ));
        let mut clauses: Vec<(Occur, Box<dyn Query>)> = vec![
            (Occur::Must, Box::new(BooleanQuery::new(should))),
            (Occur::Must, zero(set(f.vault, vaults))),
            (Occur::Must, zero(user_clause)),
        ];
        if let Some(inc) = include {
            clauses.push((Occur::Must, zero(set(f.note, inc))));
        }
        if !exclude.is_empty() {
            clauses.push((Occur::MustNot, set(f.note, exclude)));
        }
        let q = BooleanQuery::new(clauses);
        let top = TopDocs::with_limit(limit).order_by_score();
        let (n, tokens) = stats_of(&s, f, user);
        let hits = s.search_with_statistics_provider(&q, &top, &UserStats { s: &s, n, tokens })?;
        hits.into_iter()
            .map(|(score, a)| {
                let ff = s.segment_reader(a.segment_ord).fast_fields();
                let hi = ff.u64("ph")?.first(a.doc_id).unwrap_or(0);
                let lo = ff.u64("pl")?.first(a.doc_id).unwrap_or(0);
                Ok((Uuid::from_u64_pair(hi, lo), score))
            })
            .collect()
    }

    /// Every live chunk doc: (point, len, crc of its terms).
    #[cfg(any(test, feature = "harness"))]
    pub fn dump(&self) -> Vec<(Uuid, u64, u64)> {
        let s = self.reader.searcher();
        let mut out = Vec::new();
        for seg in s.segment_readers() {
            let ff = seg.fast_fields();
            let (ph, pl, len, crc) = (
                ff.u64("ph").unwrap(),
                ff.u64("pl").unwrap(),
                ff.u64("len").unwrap(),
                ff.u64("crc").unwrap(),
            );
            for doc in 0..seg.max_doc() {
                if seg.alive_bitset().is_some_and(|a| !a.is_alive(doc)) {
                    continue;
                }
                if let (Some(hi), Some(lo)) = (ph.first(doc), pl.first(doc)) {
                    out.push((
                        Uuid::from_u64_pair(hi, lo),
                        len.first(doc).unwrap(),
                        crc.first(doc).unwrap(),
                    ));
                }
            }
        }
        out
    }

    /// (segments, deleted docs) for /metrics.
    pub fn segment_stats(&self) -> (usize, u64) {
        let s = self.reader.searcher();
        let segs = s.segment_readers();
        (
            segs.len(),
            segs.iter().map(|x| x.num_deleted_docs() as u64).sum(),
        )
    }
}

fn stats_of(s: &Searcher, f: F, user: &Uuid) -> (u64, u64) {
    let mut out = (0, 0);
    for_each_doc(s, &Term::from_field_text(f.suser, &id(user)), |seg, doc| {
        let ff = seg.fast_fields();
        out = (
            ff.u64("sdocs").unwrap().first(doc).unwrap_or(0),
            ff.u64("stokens").unwrap().first(doc).unwrap_or(0),
        );
    });
    out
}

/// Calls `f` for every live doc holding `term`.
fn for_each_doc(s: &Searcher, term: &Term, mut f: impl FnMut(&SegmentReader, DocId)) {
    use tantivy::{DocSet, TERMINATED};
    for seg in s.segment_readers() {
        let Ok(inv) = seg.inverted_index(term.field()) else {
            continue;
        };
        let Ok(Some(mut p)) = inv.read_postings(term, IndexRecordOption::Basic) else {
            continue;
        };
        let alive = seg.alive_bitset();
        let mut doc = p.doc();
        while doc != TERMINATED {
            if alive.is_none_or(|a| a.is_alive(doc)) {
                f(seg, doc);
            }
            doc = p.advance();
        }
    }
}

/// BM25 over the asking user's own docs: N and the average doc length come
/// from the user's stats doc, document frequency from the user-prefixed
/// term. Tantivy's `doc_freq` still counts deleted docs until their segment
/// merges, so it is clamped to N (an idf over a df above N would go NaN).
struct UserStats<'a> {
    s: &'a Searcher,
    n: u64,
    tokens: u64,
}

impl Bm25StatisticsProvider for UserStats<'_> {
    fn total_num_tokens(&self, _field: Field) -> tantivy::Result<u64> {
        Ok(self.tokens)
    }
    fn total_num_docs(&self) -> tantivy::Result<u64> {
        Ok(self.n.max(1))
    }
    fn doc_freq(&self, term: &Term) -> tantivy::Result<u64> {
        Ok(self.s.doc_freq(term)?.min(self.n.max(1)))
    }
}
