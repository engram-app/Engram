//! 256 Tantivy shards by hash(user). Each shard is its own index; its commit
//! payload holds the feed cursor it has applied up to and its tombstones,
//! so a crash between two shard commits replays each shard exactly from
//! where IT stopped.

use crate::feed::Row;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::Path;
use std::sync::Mutex;
use std::time::Instant;
use tantivy::collector::TopDocs;
use tantivy::directory::MmapDirectory;
use tantivy::query::{
    BooleanQuery, Bm25StatisticsProvider, ConstScoreQuery, Occur, Query, TermQuery, TermSetQuery,
};
use tantivy::schema::{Field, IndexRecordOption, Schema, TextFieldIndexing, TextOptions, FAST, STRING};
use tantivy::tokenizer::{PreTokenizedString, Token};
use tantivy::{DocId, Index, IndexReader, IndexWriter, ReloadPolicy, Searcher, SegmentReader, TantivyDocument, Term};
use uuid::Uuid;

pub const SHARDS: usize = 256;

/// FNV-1a 64. Shard placement must never change across Rust releases
/// (std's DefaultHasher may), and is trivial to reproduce on the Elixir side.
pub fn fnv(bytes: &[u8]) -> u64 {
    bytes
        .iter()
        .fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ *b as u64).wrapping_mul(0x0100_0000_01b3))
}

pub fn shard_of(user: &Uuid) -> usize {
    (fnv(user.as_bytes()) % SHARDS as u64) as usize
}

/// A term token is the user's id + the HMAC dim. HMAC dims are only 32 bits,
/// so in a shard holding thousands of users two users DO share dims; without
/// the prefix their posting lists (and document frequencies) would mix.
pub fn tok(user: &Uuid, term: u32) -> String {
    format!("{}{:08x}", user.simple(), term)
}

fn id(u: &Uuid) -> String {
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
    // Per-note marker docs: the highest index stamp applied for the note.
    pub mnote: Field,
    pub muser: Field,
    pub mvault: Field,
    pub stamp: Field,
    pub mhaskeep: Field,
    pub mkeep: Field,
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
        mnote: s.add_text_field("mnote", STRING),
        muser: s.add_text_field("muser", STRING),
        mvault: s.add_text_field("mvault", STRING),
        stamp: s.add_u64_field("stamp", FAST),
        mhaskeep: s.add_u64_field("mhaskeep", FAST),
        mkeep: s.add_text_field("mkeep", STRING),
    };
    (s.build(), f)
}

/// Commit payload. `cursor` = (xid, seq) of the last feed row this shard has
/// applied (or skipped as not its own) when it committed.
#[derive(Serialize, Deserialize, Default, Clone, Debug)]
pub struct Meta {
    pub cursor: (u64, i64),
    pub tomb_users: BTreeSet<Uuid>,
    pub tomb_vaults: BTreeSet<Uuid>,
}

pub struct Writer {
    pub w: IndexWriter,
    pub used: Instant,
}

pub struct State {
    pub writer: Option<Writer>,
    pub meta: Meta,
    pub dirty: bool,
    markers: HashMap<Uuid, Marker>,
    // Points added since the last commit (not visible to the searcher yet).
    added: HashSet<Uuid>,
}

/// A note's highest applied index stamp and, if the op that set it named
/// one, the note's full point set at that stamp (`committed`: read from the
/// index, membership is a postings lookup; else `keep` holds it).
pub struct Marker {
    stamp: u64,
    keep: Option<HashSet<Uuid>>,
    committed: bool,
}

pub struct Shard {
    pub index: Index,
    pub reader: IndexReader,
    pub f: F,
    pub state: Mutex<State>,
    stats: Mutex<HashMap<Uuid, (u64, u64, u64)>>,
}

pub struct Applied {
    pub applied: u64,
    pub filled_stale: u64,
    pub skipped_stale: u64,
    pub skipped_tomb: u64,
}

impl Shard {
    pub fn open(dir: &Path) -> tantivy::Result<Shard> {
        std::fs::create_dir_all(dir)?;
        let (schema, f) = schema();
        let index = Index::open_or_create(MmapDirectory::open(dir)?, schema)?;
        let meta = index
            .load_metas()?
            .payload
            .and_then(|p| serde_json::from_str(&p).ok())
            .unwrap_or_default();
        let reader = index.reader_builder().reload_policy(ReloadPolicy::Manual).try_into()?;
        Ok(Shard {
            index,
            reader,
            f,
            state: Mutex::new(State { writer: None, meta, dirty: false, markers: HashMap::new(), added: HashSet::new() }),
            stats: Mutex::new(HashMap::new()),
        })
    }

    pub fn cursor(&self) -> (u64, i64) {
        self.state.lock().unwrap().meta.cursor
    }

    /// Applies rows in (xid, seq) order. Rows at or below the shard's
    /// committed cursor were applied before a crash and are skipped.
    pub fn apply(&self, rows: &[&Row], writer_mb: usize) -> tantivy::Result<Applied> {
        let mut st = self.state.lock().unwrap();
        let mut out = Applied { applied: 0, filled_stale: 0, skipped_stale: 0, skipped_tomb: 0 };
        let st = &mut *st;
        for r in rows {
            if (r.xid, r.seq) <= st.meta.cursor {
                continue;
            }
            if st.writer.is_none() {
                let w: IndexWriter = self.index.writer_with_num_threads(1, writer_mb << 20)?;
                // A kill -9 leaves files the dead writer created but never
                // committed (e.g. `<segment>.<opstamp>.del`). The new writer
                // restarts from the committed opstamp, reuses those names and
                // its commit fails with FileAlreadyExists. Collect them first.
                w.garbage_collect_files().wait()?;
                st.writer = Some(Writer { w, used: Instant::now() });
            }
            let w = &mut st.writer.as_mut().unwrap().w;
            let f = self.f;
            let tomb = st.meta.tomb_users.contains(&r.user)
                || r.vault.is_some_and(|v| st.meta.tomb_vaults.contains(&v));
            match r.op {
                kwfeed::DELETE_USER => {
                    w.delete_term(Term::from_field_text(f.user, &id(&r.user)));
                    w.delete_term(Term::from_field_text(f.muser, &id(&r.user)));
                    st.meta.tomb_users.insert(r.user);
                    st.markers.clear();
                }
                kwfeed::DELETE_VAULT => {
                    let v = r.vault.expect("delete_vault row without vault");
                    w.delete_term(Term::from_field_text(f.vault, &id(&v)));
                    w.delete_term(Term::from_field_text(f.mvault, &id(&v)));
                    st.meta.tomb_vaults.insert(v);
                    st.markers.clear();
                }
                _ if tomb => {
                    out.skipped_tomb += 1;
                    continue;
                }
                op => {
                    let note = r.note.expect("note op without note");
                    let vault = r.vault.expect("note op without vault");
                    let stamp = r.stamp as u64;
                    if !st.markers.contains_key(&note) {
                        let m = self.committed_marker(&note);
                        st.markers.insert(note, m);
                    }
                    let have = st.markers[&note].stamp;
                    if stamp < have {
                        // Stale: a newer pass for this note was applied first
                        // (lower xid, later commit). Its keep set says which
                        // points survive; this pass's upsert of a kept point
                        // that is not indexed yet is the only content for it.
                        // Point ids are content-derived, so an indexed point
                        // already holds this content. Everything else is a no-op.
                        let p = r.point.filter(|_| op == kwfeed::UPSERT);
                        let fill = p.is_some_and(|p| {
                            self.kept(&st.markers[&note], &note, &p) && !st.added.contains(&p) && !self.indexed(&p)
                        });
                        if !fill {
                            out.skipped_stale += 1;
                            continue;
                        }
                        let p = p.unwrap();
                        w.delete_term(Term::from_field_text(f.point, &id(&p)));
                        w.add_document(self.doc(r, &p)?)?;
                        st.added.insert(p);
                        out.filled_stale += 1;
                    } else {
                        let keep = match op {
                            kwfeed::DELETE_NOTE_EXCEPT => Some(r.keep.clone().unwrap_or_default()),
                            kwfeed::DELETE_NOTE => Some(Vec::new()),
                            _ => None,
                        };
                        if stamp > have || keep.is_some() {
                            // New marker: this pass's stamp and, when the op
                            // names it, the note's full point set.
                            w.delete_term(Term::from_field_text(f.mnote, &id(&note)));
                            let mut m = TantivyDocument::default();
                            m.add_text(f.mnote, id(&note));
                            m.add_text(f.muser, id(&r.user));
                            m.add_text(f.mvault, id(&vault));
                            m.add_u64(f.stamp, stamp);
                            m.add_u64(f.mhaskeep, keep.is_some() as u64);
                            for p in keep.iter().flatten() {
                                m.add_text(f.mkeep, id(p));
                            }
                            w.add_document(m)?;
                            let keep = keep.map(|k| k.into_iter().collect());
                            st.markers.insert(note, Marker { stamp, keep, committed: false });
                        }
                        match op {
                            kwfeed::UPSERT => {
                                let p = r.point.expect("upsert without point");
                                w.delete_term(Term::from_field_text(f.point, &id(&p)));
                                w.add_document(self.doc(r, &p)?)?;
                                st.added.insert(p);
                            }
                            kwfeed::DELETE_POINTS => {
                                let p = r.point.expect("delete_points without point");
                                w.delete_term(Term::from_field_text(f.point, &id(&p)));
                                st.added.remove(&p);
                                if let Some(k) = st.markers.get_mut(&note).and_then(|m| m.keep.as_mut()) {
                                    k.remove(&p);
                                }
                            }
                            kwfeed::DELETE_NOTE => {
                                w.delete_term(Term::from_field_text(f.note, &id(&note)));
                            }
                            kwfeed::DELETE_NOTE_EXCEPT => {
                                let keep: Vec<Term> =
                                    r.keep.iter().flatten().map(|p| Term::from_field_text(f.point, &id(p))).collect();
                                let q = BooleanQuery::new(vec![
                                    (Occur::Must, Box::new(TermQuery::new(
                                        Term::from_field_text(f.note, &id(&note)),
                                        IndexRecordOption::Basic,
                                    )) as Box<dyn Query>),
                                    (Occur::MustNot, Box::new(TermSetQuery::new(keep))),
                                ]);
                                w.delete_query(Box::new(q))?;
                            }
                            other => panic!("unknown feed op {other}"),
                        }
                    }
                }
            }
            out.applied += 1;
            st.dirty = true;
        }
        Ok(out)
    }

    fn doc(&self, r: &Row, p: &Uuid) -> tantivy::Result<TantivyDocument> {
        let f = self.f;
        let raw = r.terms.as_deref().unwrap_or_default();
        let pairs = kwfeed::unpack(raw)
            .ok_or_else(|| tantivy::TantivyError::InvalidArgument("ragged terms".into()))?;
        let mut tokens = Vec::new();
        for (term, n) in pairs {
            let text = tok(&r.user, term);
            for _ in 0..n {
                tokens.push(Token { position: tokens.len(), text: text.clone(), ..Token::default() });
            }
        }
        let len = tokens.len() as u64;
        let mut d = TantivyDocument::default();
        d.add_pre_tokenized_text(f.t, PreTokenizedString { text: String::new(), tokens });
        d.add_text(f.point, id(p));
        d.add_text(f.note, id(&r.note.unwrap()));
        d.add_text(f.vault, id(&r.vault.expect("upsert without vault")));
        d.add_text(f.user, id(&r.user));
        let (hi, lo) = p.as_u64_pair();
        d.add_u64(f.ph, hi);
        d.add_u64(f.pl, lo);
        d.add_u64(f.len, len);
        d.add_u64(f.crc, fnv(raw));
        Ok(d)
    }

    /// Commits pending ops with the round's cursor and reloads the reader.
    pub fn commit(&self, cursor: (u64, i64)) -> tantivy::Result<bool> {
        let mut st = self.state.lock().unwrap();
        st.meta.cursor = cursor;
        if !st.dirty {
            return Ok(false);
        }
        let payload = serde_json::to_string(&st.meta).unwrap();
        let w = &mut st.writer.as_mut().expect("dirty shard without writer");
        let mut prepared = w.w.prepare_commit()?;
        prepared.set_payload(&payload);
        prepared.commit()?;
        w.used = Instant::now();
        st.dirty = false;
        st.markers.clear();
        st.added.clear();
        drop(st);
        self.reader.reload()?;
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

    fn committed_marker(&self, note: &Uuid) -> Marker {
        let s = self.reader.searcher();
        let mut m = Marker { stamp: 0, keep: None, committed: false };
        for_each_doc(&s, &Term::from_field_text(self.f.mnote, &id(note)), true, |seg, doc| {
            let ff = seg.fast_fields();
            m.stamp = m.stamp.max(ff.u64("stamp").unwrap().first(doc).unwrap_or(0));
            m.committed = ff.u64("mhaskeep").unwrap().first(doc) == Some(1);
        });
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
        let s = self.reader.searcher();
        let q = BooleanQuery::new(vec![
            (Occur::Must, Box::new(TermQuery::new(Term::from_field_text(self.f.mnote, &id(note)), IndexRecordOption::Basic)) as Box<dyn Query>),
            (Occur::Must, Box::new(TermQuery::new(Term::from_field_text(self.f.mkeep, &id(p)), IndexRecordOption::Basic))),
        ]);
        s.search(&q, &tantivy::collector::Count).unwrap() > 0
    }

    fn indexed(&self, p: &Uuid) -> bool {
        let mut any = false;
        for_each_doc(&self.reader.searcher(), &Term::from_field_text(self.f.point, &id(p)), true, |_, _| any = true);
        any
    }

    /// Per-user BM25 statistics: (docs, tokens) over the user's docs,
    /// deleted-not-yet-merged ones included, the same way Tantivy's own
    /// shard-wide statistics and `doc_freq` count them. Cached per searcher
    /// generation (one recompute per user per commit of its shard).
    fn user_stats(&self, s: &Searcher, user: &Uuid) -> (u64, u64) {
        let gen = s.generation().generation_id();
        if let Some((g, n, t)) = self.stats.lock().unwrap().get(user) {
            if *g == gen {
                return (*n, *t);
            }
        }
        let (mut n, mut t) = (0u64, 0u64);
        for_each_doc(s, &Term::from_field_text(self.f.user, &id(user)), false, |seg, doc| {
            n += 1;
            t += seg.fast_fields().u64("len").unwrap().first(doc).unwrap_or(0);
        });
        let mut c = self.stats.lock().unwrap();
        if c.len() > 50_000 {
            c.clear(); // ponytail: wholesale clear; an LRU if hot users thrash it
        }
        c.insert(*user, (gen, n, t));
        (n, t)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn search(
        &self,
        user: &Uuid,
        vaults: &[Uuid],
        terms: &[u32],
        include: Option<&[Uuid]>,
        exclude: &[Uuid],
        limit: usize,
        shard_stats: bool,
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
            Box::new(TermSetQuery::new(ids.iter().map(|u| Term::from_field_text(field, &id(u)))))
        };
        let zero = |q: Box<dyn Query>| -> Box<dyn Query> { Box::new(ConstScoreQuery::new(q, 0.0)) };
        let mut clauses: Vec<(Occur, Box<dyn Query>)> = vec![
            (Occur::Must, Box::new(BooleanQuery::new(should))),
            (Occur::Must, zero(set(f.vault, vaults))),
        ];
        if let Some(inc) = include {
            clauses.push((Occur::Must, zero(set(f.note, inc))));
        }
        if !exclude.is_empty() {
            clauses.push((Occur::MustNot, set(f.note, exclude)));
        }
        let q = BooleanQuery::new(clauses);
        let top = TopDocs::with_limit(limit).order_by_score();
        let hits = if shard_stats {
            s.search(&q, &top)?
        } else {
            let (n, tokens) = self.user_stats(&s, user);
            s.search_with_statistics_provider(&q, &top, &UserStats { s: &s, n, tokens })?
        };
        Ok(hits
            .into_iter()
            .map(|(score, a)| {
                let seg = s.segment_reader(a.segment_ord);
                let ff = seg.fast_fields();
                let hi = ff.u64("ph").unwrap().first(a.doc_id).unwrap();
                let lo = ff.u64("pl").unwrap().first(a.doc_id).unwrap();
                (Uuid::from_u64_pair(hi, lo), score)
            })
            .collect())
    }

    /// Every live point doc: (point, user, vault-less summary for verify).
    pub fn dump(&self) -> Vec<(Uuid, u64, u64)> {
        let s = self.reader.searcher();
        let mut out = Vec::new();
        for seg in s.segment_readers() {
            let ff = seg.fast_fields();
            let (ph, pl, len, crc) =
                (ff.u64("ph").unwrap(), ff.u64("pl").unwrap(), ff.u64("len").unwrap(), ff.u64("crc").unwrap());
            for doc in 0..seg.max_doc() {
                if seg.alive_bitset().is_some_and(|a| !a.is_alive(doc)) {
                    continue;
                }
                if let (Some(hi), Some(lo)) = (ph.first(doc), pl.first(doc)) {
                    out.push((Uuid::from_u64_pair(hi, lo), len.first(doc).unwrap(), crc.first(doc).unwrap()));
                }
            }
        }
        out
    }
}

/// Calls `f` for every doc holding `term` (alive only, or all).
fn for_each_doc(s: &Searcher, term: &Term, alive_only: bool, mut f: impl FnMut(&SegmentReader, DocId)) {
    use tantivy::{DocSet, TERMINATED};
    for seg in s.segment_readers() {
        let inv = seg.inverted_index(term.field()).unwrap();
        let Some(mut p) = inv.read_postings(term, IndexRecordOption::Basic).unwrap() else {
            continue;
        };
        let alive = seg.alive_bitset();
        let mut doc = p.doc();
        while doc != TERMINATED {
            if !alive_only || alive.is_none_or(|a| a.is_alive(doc)) {
                f(seg, doc);
            }
            doc = p.advance();
        }
    }
}

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
        self.s.doc_freq(term)
    }
}
