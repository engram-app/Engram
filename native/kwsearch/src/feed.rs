//! Commit-safe `keyword_feed` reader and the writer loop.
//!
//! A bigserial is not commit-ordered: seq 101 can commit after 102. So each
//! read takes xmin of a fresh snapshot and reads only rows with xid < xmin
//! (every such transaction has finished; no new row can get a lower xid),
//! ordered by (xid, seq). Ops are idempotent, so at-least-once is enough.
//!
//! The connection is TLS only, verified against the configured CA bundle
//! and the server's host name (security F6: `verify-full`).

use crate::row::Row;
use crate::shard::{shard_of, Shard, SHARDS};
use postgres::config::SslMode;
use postgres::Client;
use std::collections::BTreeMap;
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

const SNAPSHOT: &str =
    "SELECT pg_snapshot_xmin(s)::text, pg_snapshot_xmax(s)::text FROM pg_current_snapshot() s";

// The read lives in its own file so an Elixir test can run the exact text
// in CI (test/engram/keyword_store/tantivy_feed_read_sql_test.exs).
// `xid::text` is aliased there: unaliased, the output column is named `xid`
// and `ORDER BY xid` sorts by that TEXT ("1000" < "883") while the WHERE
// compares the real xid8, so the cursor skipped rows for good once xids
// crossed a digit-count boundary.
const READ: &str = include_str!("../sql/read.sql");

const HORIZON: &str = "SELECT xid::text AS xid_text, seq FROM keyword_feed_horizon WHERE id = 1";

const DELETIONS: &str = "SELECT xid::text AS xid_text, user_id, op, vault_id, note_id
  FROM keyword_deletions WHERE xid >= $1::text::xid8 ORDER BY xid, seq";

/// One read: the rows, the snapshot's xmin (every row below it that exists
/// is visible) and whether the read came back short (feed drained to xmin).
pub struct Read {
    pub rows: Vec<Row>,
    pub xmin: u64,
    pub drained: bool,
}

pub fn read(db: &mut Client, cursor: (u64, i64), limit: i64) -> Result<Read, postgres::Error> {
    let snap = db.query_one(SNAPSHOT, &[])?;
    let xmin: String = snap.get(0);
    let xmax: u64 = snap.get::<_, String>(1).parse().unwrap_or(u64::MAX);
    let rows = db.query(READ, &[&cursor.0.to_string(), &cursor.1, &xmin, &limit])?;
    let drained = (rows.len() as i64) < limit;
    let rows = rows
        .iter()
        .map(|r| Row {
            seq: r.get(0),
            xid: r.get::<_, String>(1).parse().unwrap_or(0),
            xmax,
            user: r.get(2),
            gen: r.get(3),
            op: r.get(4),
            vault: r.get(5),
            note: r.get(6),
            point: r.get(7),
            stamp: r.get(8),
            terms: r.get(9),
            keep: r.get(10),
        })
        .collect();
    Ok(Read {
        rows,
        xmin: xmin.parse().unwrap_or(0),
        drained,
    })
}

/// TLS connection to the feed database.
pub fn connect(url: &str, password: Option<&str>, ca_file: &Path) -> Result<Client, String> {
    let mut roots = rustls::RootCertStore::empty();
    let pem = std::fs::File::open(ca_file).map_err(|e| format!("CA bundle: {e}"))?;
    for c in rustls_pemfile::certs(&mut BufReader::new(pem)) {
        roots
            .add(c.map_err(|e| format!("CA bundle: {e}"))?)
            .map_err(|e| format!("CA bundle: {e}"))?;
    }
    if roots.is_empty() {
        return Err("CA bundle holds no certificate".into());
    }
    let tls = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .map_err(|e| e.to_string())?
    .with_root_certificates(roots)
    .with_no_client_auth();
    let mut cfg: postgres::Config = url.parse().map_err(|e: postgres::Error| e.to_string())?;
    // Whatever the URL says: TLS or no connection.
    cfg.ssl_mode(SslMode::Require);
    if let Some(p) = password {
        cfg.password(p);
    }
    cfg.connect(tokio_postgres_rustls::MakeRustlsConnect::new(tls))
        .map_err(|e| e.to_string())
}

/// One generation's 256 shards (generation = index set: the 1x chunk set
/// now, the 2x one beside it in P3).
pub struct Shards {
    pub shards: Vec<Shard>,
}

impl Shards {
    pub fn open(dir: &Path) -> tantivy::Result<Shards> {
        let shards = (0..SHARDS)
            .map(|i| Shard::open(&dir.join(format!("s{i:03}"))))
            .collect::<tantivy::Result<_>>()?;
        Ok(Shards { shards })
    }

    pub fn of(&self, user: &Uuid) -> &Shard {
        &self.shards[shard_of(user)]
    }
}

pub struct Index {
    pub dir: PathBuf,
    pub gens: BTreeMap<i16, Shards>,
}

impl Index {
    pub fn open(dir: &Path, gens: &[i16]) -> tantivy::Result<Index> {
        let gens = gens
            .iter()
            .map(|g| Ok((*g, Shards::open(&dir.join(format!("g{g}")))?)))
            .collect::<tantivy::Result<_>>()?;
        Ok(Index {
            dir: dir.to_path_buf(),
            gens,
        })
    }

    pub fn all(&self) -> impl Iterator<Item = &Shard> {
        self.gens.values().flat_map(|s| s.shards.iter())
    }

    /// Where a restart resumes: the lowest committed shard cursor, or the
    /// `round` file (written after every fully committed round) when higher.
    pub fn resume(&self) -> (u64, i64) {
        let low = self.all().map(|s| s.cursor()).min().unwrap_or_default();
        std::fs::read_to_string(self.dir.join("round"))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .map_or(low, |r: (u64, i64)| r.max(low))
    }

    pub fn save_round(&self, cursor: (u64, i64)) -> std::io::Result<()> {
        let tmp = self.dir.join("round.tmp");
        std::fs::write(&tmp, serde_json::to_string(&cursor).unwrap())?;
        std::fs::File::open(&tmp)?.sync_all()?;
        std::fs::rename(tmp, self.dir.join("round"))
    }
}

#[derive(Default)]
pub struct Stats {
    /// Boot restore done and no feed gap: /search may answer.
    pub ready: AtomicBool,
    /// The feed trim deleted rows this node never applied (max age): the
    /// index is missing data until a rebuild.
    pub gap: AtomicBool,
    pub cursor_xid: AtomicU64,
    pub cursor_seq: AtomicU64,
    /// Unix seconds the feed was last read to its end.
    pub drained_at: AtomicU64,
    pub rows: AtomicU64,
    pub rounds: AtomicU64,
    pub commits: AtomicU64,
    pub writers_open: AtomicU64,
    pub skipped_stale: AtomicU64,
    pub filled_stale: AtomicU64,
    pub skipped_tomb: AtomicU64,
    pub skipped_gen: AtomicU64,
    pub skipped_malformed: AtomicU64,
    pub purges: AtomicU64,
    pub restored_deletes: AtomicU64,
    pub searches: AtomicU64,
    pub search_errors: AtomicU64,
    pub unauthorized: AtomicU64,
    pub window: AtomicU64,
}

impl Stats {
    pub fn lag_s(&self) -> u64 {
        now().saturating_sub(self.drained_at.load(Relaxed))
    }
}

pub struct Cfg {
    pub url: String,
    pub password: Option<String>,
    pub ca_file: PathBuf,
    pub batch: i64,
    /// Rows per round when caught up; doubles under backlog up to `max_window`.
    pub window: usize,
    pub max_window: usize,
    pub round: Duration,
    pub writer_mb: usize,
    pub max_writers: usize,
    pub writer_idle: Duration,
    pub tomb_ttl_s: u64,
    /// Force-merge a shard whose oldest unpurged delete is older than this.
    pub purge_after_s: u64,
}

fn connect_retry(cfg: &Cfg) -> Client {
    loop {
        match connect(&cfg.url, cfg.password.as_deref(), &cfg.ca_file) {
            Ok(c) => return c,
            Err(e) => {
                eprintln!("feed connect failed: {e}");
                std::thread::sleep(Duration::from_secs(2));
            }
        }
    }
}

/// Applies the durable deletion log when the feed has a gap for this node
/// (rows it never applied were trimmed: a node restored from a snapshot, or
/// one that fell past the maximum feed age). Without it a restored snapshot
/// would serve docs deleted after it was taken (R3 "Failures"). Every delete
/// at or above a shard's cursor xid is applied as a hard delete.
///
/// Only on a gap, never on a normal restart: the log has no note stamps, so
/// replaying a note delete could remove a newer pass of the note that took a
/// lower xid and is already applied. On a gap the node stays down until a
/// rebuild re-creates every live doc, so deleting too much is harmless and
/// deleting too little is what this prevents.
pub fn restore(db: &mut Client, index: &Index, cfg: &Cfg, stats: &Stats) -> Result<u64, String> {
    let low = index.all().map(|s| s.cursor().0).min().unwrap_or(0);
    let rows = db
        .query(DELETIONS, &[&low.to_string()])
        .map_err(|e| e.to_string())?;
    let now = now();
    let mut n = 0;
    for r in rows {
        let xid: u64 = r.get::<_, String>(0).parse().unwrap_or(0);
        let user: Uuid = r.get(1);
        let (op, vault, note): (i16, Option<Uuid>, Option<Uuid>) = (r.get(2), r.get(3), r.get(4));
        for shards in index.gens.values() {
            let s = shards.of(&user);
            if xid >= s.cursor().0
                && s.apply_deletion(op, &user, vault, note, cfg.writer_mb, now)
                    .map_err(|e| e.to_string())?
            {
                n += 1;
            }
        }
    }
    for s in index.all() {
        let c = s.cursor();
        if s.commit(c, 0, now, cfg.tomb_ttl_s)
            .map_err(|e| e.to_string())?
        {
            s.purge(cfg.writer_mb).map_err(|e| e.to_string())?;
            s.commit(c, 0, now, cfg.tomb_ttl_s)
                .map_err(|e| e.to_string())?;
            s.close_writer();
        }
    }
    stats.restored_deletes.store(n, Relaxed);
    Ok(n)
}

/// The writer loop: boot restore, then rounds forever. Never returns; any
/// error panics, and `main` turns a panic here into a process exit so the
/// supervisor restarts it and /health cannot report a frozen index as up.
///
/// One round: read up to `window` rows or until the feed is drained or
/// `round` elapses, then walk the shards in order: apply that shard's rows,
/// commit it with the round's end cursor, and close the least recently used
/// writers once more than `max_writers` are open. A crash at any point
/// leaves each shard at its last commit; the next start replays from
/// `resume()` and each shard skips what it already has.
pub fn run(index: Arc<Index>, cfg: Cfg, stats: Arc<Stats>) -> ! {
    let mut db = connect_retry(&cfg);
    let mut cursor = index.resume();
    eprintln!("feed resume at {cursor:?}");
    // Serve only once the horizon is known: a restored node must not answer
    // before its gap is detected.
    while !check_horizon(&mut db, &index, &cfg, cursor, &stats) {
        std::thread::sleep(Duration::from_secs(2));
        db = connect_retry(&cfg);
    }
    // Not ready yet: a node restored from a snapshot still inside the feed
    // window must replay up to the feed head (its deletes included) before
    // it answers a search. `ready` goes up after the first drained round.
    // Test hooks: abort (no cleanup, like kill -9) after this many shard
    // commits; panic in the loop after this many rounds.
    let crash_at: u64 = crate::env("KW_CRASH_AFTER_COMMITS", "0")
        .parse()
        .unwrap_or(0);
    let panic_at: u64 = crate::env("KW_PANIC_AFTER_ROUNDS", "0")
        .parse()
        .unwrap_or(0);
    let mut window = cfg.window;
    let mut last_purge_check = Instant::now();
    loop {
        let start = Instant::now();
        let mut rows: Vec<Row> = Vec::new();
        let mut watermark = cursor.0;
        let mut drained = false;
        while start.elapsed() < cfg.round && rows.len() < window {
            let r = match read(&mut db, cursor, cfg.batch) {
                Ok(r) => r,
                Err(e) => {
                    eprintln!("feed read failed: {e}");
                    db = connect_retry(&cfg);
                    break;
                }
            };
            if let Some(last) = r.rows.last() {
                cursor = (last.xid, last.seq);
            }
            watermark = if r.drained { r.xmin } else { cursor.0 };
            rows.extend(r.rows);
            if r.drained {
                drained = true;
                break;
            }
        }
        // Grow rounds under backlog: shard commits (~70 ms each) bound
        // catch-up, so fewer, bigger rounds drain a burst about twice as fast.
        window = if rows.len() >= window {
            (window * 2).min(cfg.max_window)
        } else {
            cfg.window
        };
        stats.window.store(window as u64, Relaxed);
        apply_round(&index, &cfg, &stats, &rows, cursor, watermark, crash_at);
        index.save_round(cursor).expect("save round cursor");
        stats.cursor_xid.store(cursor.0, Relaxed);
        stats.cursor_seq.store(cursor.1.max(0) as u64, Relaxed);
        stats.rows.fetch_add(rows.len() as u64, Relaxed);
        let n = stats.rounds.fetch_add(1, Relaxed) + 1;
        if drained {
            stats.drained_at.store(now(), Relaxed);
            if !stats.gap.load(Relaxed) && !stats.ready.swap(true, Relaxed) {
                eprintln!("feed caught up: serving");
            }
        }
        check_horizon(&mut db, &index, &cfg, cursor, &stats);
        if last_purge_check.elapsed() > Duration::from_secs(60) {
            purge_old(&index, &cfg, &stats);
            last_purge_check = Instant::now();
        }
        close_idle(&index, &cfg, &stats);
        if panic_at > 0 && n >= panic_at {
            panic!("KW_PANIC_AFTER_ROUNDS test hook");
        }
        if rows.is_empty() {
            std::thread::sleep(Duration::from_millis(200));
        }
    }
}

fn apply_round(
    index: &Index,
    cfg: &Cfg,
    stats: &Stats,
    rows: &[Row],
    cursor: (u64, i64),
    watermark: u64,
    crash_at: u64,
) {
    let now = now();
    for (gen, shards) in &index.gens {
        let mut by: Vec<Vec<&Row>> = vec![Vec::new(); SHARDS];
        for r in rows.iter().filter(|r| r.gen == *gen) {
            by[shard_of(&r.user)].push(r);
        }
        for (i, rs) in by.iter().enumerate() {
            let shard = &shards.shards[i];
            if !rs.is_empty() {
                let a = shard.apply(rs, cfg.writer_mb, now).expect("apply");
                stats.skipped_stale.fetch_add(a.skipped_stale, Relaxed);
                stats.filled_stale.fetch_add(a.filled_stale, Relaxed);
                stats.skipped_tomb.fetch_add(a.skipped_tomb, Relaxed);
                stats
                    .skipped_malformed
                    .fetch_add(a.skipped_malformed, Relaxed);
            }
            if shard
                .commit(cursor, watermark, now, cfg.tomb_ttl_s)
                .expect("commit")
            {
                let n = stats.commits.fetch_add(1, Relaxed) + 1;
                if n == crash_at {
                    eprintln!(
                        "KW_CRASH_AFTER_COMMITS: abort after commit {n} (gen {gen} shard {i})"
                    );
                    std::process::abort();
                }
                // delete_user / delete_vault: their docs leave the disk now (F1).
                if shard.state.lock().unwrap().purge_now
                    && shard.purge(cfg.writer_mb).expect("purge")
                {
                    shard
                        .commit(cursor, watermark, now, cfg.tomb_ttl_s)
                        .expect("commit after purge");
                    stats.purges.fetch_add(1, Relaxed);
                }
                if open_writers(index) > cfg.max_writers {
                    close_lru(index, cfg.max_writers);
                }
            }
        }
    }
    let known = |r: &&Row| index.gens.contains_key(&r.gen);
    stats
        .skipped_gen
        .fetch_add(rows.iter().filter(|r| !known(r)).count() as u64, Relaxed);
}

/// Scheduled purge: any shard whose oldest unpurged delete is older than
/// `purge_after_s` is force-merged (F1: deleted docs leave the disk within
/// that bound even when the merge policy never picks their segment).
fn purge_old(index: &Index, cfg: &Cfg, stats: &Stats) {
    let cutoff = now().saturating_sub(cfg.purge_after_s);
    for s in index.all() {
        if s.first_delete_at().is_some_and(|t| t <= cutoff)
            && s.purge(cfg.writer_mb).expect("purge")
        {
            let c = s.cursor();
            s.commit(c, 0, now(), cfg.tomb_ttl_s)
                .expect("commit after purge");
            stats.purges.fetch_add(1, Relaxed);
            s.close_writer();
        }
    }
}

/// A trim horizon above our cursor means rows are gone that this node never
/// applied: apply the deletion log, then stop serving until a rebuild.
/// Returns false when the horizon could not be read (try next round).
fn check_horizon(
    db: &mut Client,
    index: &Index,
    cfg: &Cfg,
    cursor: (u64, i64),
    stats: &Stats,
) -> bool {
    let h = match db.query_opt(HORIZON, &[]) {
        Ok(Some(r)) => (
            r.get::<_, String>(0).parse().unwrap_or(0),
            r.get::<_, i64>(1),
        ),
        // The migration seeds the row; a missing one means the table was
        // tampered with, so gap detection cannot be trusted (review #10).
        Ok(None) => {
            eprintln!("feed horizon row missing: not serving");
            stats.ready.store(false, Relaxed);
            return false;
        }
        Err(e) => {
            eprintln!("feed horizon read failed: {e}");
            return false;
        }
    };
    if h > cursor && !stats.gap.swap(true, Relaxed) {
        stats.ready.store(false, Relaxed);
        eprintln!(
            "feed gap: rows up to {h:?} were trimmed before this node applied them; rebuild needed"
        );
        let n = restore(db, index, cfg, stats).expect("deletion log restore");
        eprintln!("{n} deletion-log deletes applied");
    }
    true
}

fn open_writers(index: &Index) -> usize {
    index
        .all()
        .filter(|s| s.state.lock().unwrap().writer.is_some())
        .count()
}

/// Closes the least recently used clean writers down to `keep`.
fn close_lru(index: &Index, keep: usize) {
    let shards: Vec<&Shard> = index.all().collect();
    let mut by_age: Vec<(Instant, usize)> = shards
        .iter()
        .enumerate()
        .filter_map(|(i, s)| {
            let st = s.state.lock().unwrap();
            st.writer
                .as_ref()
                .filter(|_| !st.dirty)
                .map(|w| (w.used, i))
        })
        .collect();
    by_age.sort();
    let open = open_writers(index);
    let mut closed = false;
    for (_, i) in by_age.iter().take(open.saturating_sub(keep)) {
        closed |= shards[*i].close_writer();
    }
    if closed {
        crate::trim_heap();
    }
}

fn close_idle(index: &Index, cfg: &Cfg, stats: &Stats) {
    let mut closed = false;
    for s in index.all() {
        let idle = s
            .state
            .lock()
            .unwrap()
            .writer
            .as_ref()
            .is_some_and(|w| w.used.elapsed() > cfg.writer_idle);
        if idle {
            closed |= s.close_writer();
        }
    }
    if closed {
        crate::trim_heap();
    }
    stats
        .writers_open
        .store(open_writers(index) as u64, Relaxed);
}
