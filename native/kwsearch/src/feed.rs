//! Commit-safe `keyword_feed` reader and the writer loop.
//!
//! A bigserial is not commit-ordered: seq 101 can commit after 102. So each
//! read takes xmin of a fresh snapshot and reads only rows with xid < xmin
//! (every such transaction has finished; no new row can get a lower xid),
//! ordered by (xid, seq). Ops are idempotent, so at-least-once is enough.

use crate::shard::{shard_of, Shard, SHARDS};
use postgres::{Client, NoTls};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::sync::Arc;
use std::time::{Duration, Instant};
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct Row {
    pub seq: i64,
    pub xid: u64,
    pub user: Uuid,
    pub op: i16,
    pub vault: Option<Uuid>,
    pub note: Option<Uuid>,
    pub point: Option<Uuid>,
    pub stamp: i64,
    pub terms: Option<Vec<u8>>,
    pub keep: Option<Vec<Uuid>>,
}

const READ: &str = "SELECT seq, xid::text, user_id, op, vault_id, note_id, point_id, stamp, terms, keep
  FROM keyword_feed
  WHERE (xid, seq) > ($1::text::xid8, $2) AND xid < $3::text::xid8
  ORDER BY xid, seq LIMIT $4";

pub fn read(db: &mut Client, cursor: (u64, i64), limit: i64) -> Result<Vec<Row>, postgres::Error> {
    let xmin: String = db.query_one("SELECT pg_snapshot_xmin(pg_current_snapshot())::text", &[])?.get(0);
    let rows = db.query(READ, &[&cursor.0.to_string(), &cursor.1, &xmin, &limit])?;
    Ok(rows
        .iter()
        .map(|r| Row {
            seq: r.get(0),
            xid: r.get::<_, String>(1).parse().unwrap(),
            user: r.get(2),
            op: r.get(3),
            vault: r.get(4),
            note: r.get(5),
            point: r.get(6),
            stamp: r.get(7),
            terms: r.get(8),
            keep: r.get(9),
        })
        .collect())
}

pub struct Shards {
    pub dir: PathBuf,
    pub shards: Vec<Shard>,
}

impl Shards {
    pub fn open(dir: &Path) -> Shards {
        let shards = (0..SHARDS)
            .map(|i| Shard::open(&dir.join(format!("s{i:03}"))).expect("open shard"))
            .collect();
        Shards { dir: dir.to_path_buf(), shards }
    }

    pub fn of(&self, user: &Uuid) -> &Shard {
        &self.shards[shard_of(user)]
    }

    /// Where a restart resumes: the lowest committed shard cursor. A shard's
    /// cursor only moves when that shard commits, so a shard idle for a
    /// while holds this back and its replay is a no-op read; the
    /// `round` file (written after every round) is the faster lower bound.
    pub fn resume(&self) -> (u64, i64) {
        let low = self.shards.iter().map(|s| s.cursor()).min().unwrap_or_default();
        std::fs::read_to_string(self.dir.join("round"))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .map_or(low, |r: (u64, i64)| r.max(low))
    }

    fn save_round(&self, cursor: (u64, i64)) {
        let tmp = self.dir.join("round.tmp");
        std::fs::write(&tmp, serde_json::to_string(&cursor).unwrap()).unwrap();
        std::fs::File::open(&tmp).unwrap().sync_all().unwrap();
        std::fs::rename(tmp, self.dir.join("round")).unwrap();
    }
}

#[derive(Default)]
pub struct Stats {
    pub cursor_xid: AtomicU64,
    pub rows: AtomicU64,
    pub rounds: AtomicU64,
    pub commits: AtomicU64,
    pub writers_open: AtomicU64,
    pub writers_peak: AtomicU64,
    pub skipped_stale: AtomicU64,
    pub filled_stale: AtomicU64,
    pub apply_ms: AtomicU64,
    pub commit_ms: AtomicU64,
    pub close_ms: AtomicU64,
    pub skipped_tomb: AtomicU64,
}

pub struct Cfg {
    pub url: String,
    pub batch: i64,
    pub window: usize,
    pub round: Duration,
    pub writer_mb: usize,
    pub max_writers: usize,
    pub writer_idle: Duration,
}

/// One round: read up to `window` rows (batches of `batch`) or until the
/// feed is drained or `round` elapses, then walk the shards in order: apply
/// that shard's rows, commit it with the window's end cursor, and close the
/// least recently used writers once more than `max_writers` are open. So a
/// burst that dirties every shard costs one commit per shard per round and
/// never holds more than `max_writers` writers. A crash at any point leaves
/// each shard at its last commit; the next start replays from `resume()`
/// and each shard skips what it already has.
pub fn run(shards: Arc<Shards>, cfg: Cfg, stats: Arc<Stats>) -> ! {
    let mut db = loop {
        match Client::connect(&cfg.url, NoTls) {
            Ok(c) => break c,
            Err(e) => {
                eprintln!("feed connect: {e}");
                std::thread::sleep(Duration::from_secs(1));
            }
        }
    };
    let mut cursor = shards.resume();
    eprintln!("feed resume at {cursor:?}");
    // Test hook: abort (no cleanup, like kill -9) after this many shard
    // commits, i.e. between two shard commits of one round.
    let crash_at: u64 = crate::env("KW_CRASH_AFTER_COMMITS", "0").parse().unwrap();
    loop {
        let start = Instant::now();
        let mut rows: Vec<Row> = Vec::new();
        while start.elapsed() < cfg.round && rows.len() < cfg.window {
            let batch = read(&mut db, cursor, cfg.batch).expect("feed read");
            let full = batch.len() as i64 == cfg.batch;
            if let Some(last) = batch.last() {
                cursor = (last.xid, last.seq);
            }
            rows.extend(batch);
            if !full {
                break;
            }
        }
        let mut by: Vec<Vec<&Row>> = vec![Vec::new(); SHARDS];
        for r in &rows {
            by[shard_of(&r.user)].push(r);
        }
        for (i, rs) in by.iter().enumerate() {
            let shard = &shards.shards[i];
            if !rs.is_empty() {
                let t = Instant::now();
                let a = shard.apply(rs, cfg.writer_mb).expect("apply");
                stats.apply_ms.fetch_add(t.elapsed().as_millis() as u64, Relaxed);
                stats.skipped_stale.fetch_add(a.skipped_stale, Relaxed);
                stats.filled_stale.fetch_add(a.filled_stale, Relaxed);
                stats.skipped_tomb.fetch_add(a.skipped_tomb, Relaxed);
                stats.writers_peak.fetch_max(open_writers(&shards) as u64, Relaxed);
            }
            let t = Instant::now();
            let committed = shard.commit(cursor).expect("commit");
            stats.commit_ms.fetch_add(t.elapsed().as_millis() as u64, Relaxed);
            if committed {
                let n = stats.commits.fetch_add(1, Relaxed) + 1;
                if n == crash_at {
                    eprintln!("KW_CRASH_AFTER_COMMITS: abort after commit {n} (shard {i})");
                    std::process::abort();
                }
                if open_writers(&shards) > cfg.max_writers {
                    let t = Instant::now();
                    close_lru(&shards, cfg.max_writers);
                    stats.close_ms.fetch_add(t.elapsed().as_millis() as u64, Relaxed);
                }
            }
        }
        shards.save_round(cursor);
        stats.cursor_xid.store(cursor.0, Relaxed);
        stats.rows.fetch_add(rows.len() as u64, Relaxed);
        stats.rounds.fetch_add(1, Relaxed);
        close_idle(&shards, &cfg, &stats);
        if rows.is_empty() {
            std::thread::sleep(Duration::from_millis(200));
        }
    }
}

fn open_writers(shards: &Shards) -> usize {
    shards.shards.iter().filter(|s| s.state.lock().unwrap().writer.is_some()).count()
}

/// Closes the least recently used clean writers down to `keep`.
fn close_lru(shards: &Shards, keep: usize) {
    let mut by_age: Vec<(Instant, usize)> = shards
        .shards
        .iter()
        .enumerate()
        .filter_map(|(i, s)| {
            let st = s.state.lock().unwrap();
            st.writer.as_ref().filter(|_| !st.dirty).map(|w| (w.used, i))
        })
        .collect();
    by_age.sort();
    let open = open_writers(shards);
    for (_, i) in by_age.iter().take(open.saturating_sub(keep)) {
        shards.shards[*i].close_writer();
    }
}

fn close_idle(shards: &Shards, cfg: &Cfg, stats: &Stats) {
    for s in &shards.shards {
        let idle = s.state.lock().unwrap().writer.as_ref().is_some_and(|w| w.used.elapsed() > cfg.writer_idle);
        if idle {
            s.close_writer();
        }
    }
    stats.writers_open.store(open_writers(shards) as u64, Relaxed);
}
