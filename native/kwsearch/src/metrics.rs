//! Prometheus text for GET /metrics. Labels by generation and shard number
//! only, never by user (security F15).

use crate::feed::{now, Index, Stats};
use std::fmt::Write;
use std::sync::atomic::Ordering::Relaxed;

pub fn render(index: &Index, s: &Stats) -> String {
    let mut o = String::new();
    let mut put = |name: &str, kind: &str, help: &str, v: u64| {
        let _ = writeln!(
            o,
            "# HELP kwsearch_{name} {help}\n# TYPE kwsearch_{name} {kind}\nkwsearch_{name} {v}"
        );
    };
    put(
        "up",
        "gauge",
        "1 when the index serves searches",
        s.ready.load(Relaxed) as u64,
    );
    put(
        "feed_gap",
        "gauge",
        "1 when feed rows were trimmed before this node applied them",
        s.gap.load(Relaxed) as u64,
    );
    put(
        "feed_lag_seconds",
        "gauge",
        "Seconds since the feed was last read to its end",
        s.lag_s(),
    );
    put(
        "feed_rows_total",
        "counter",
        "Feed rows read",
        s.rows.load(Relaxed),
    );
    put(
        "feed_rounds_total",
        "counter",
        "Writer rounds",
        s.rounds.load(Relaxed),
    );
    put(
        "feed_window_rows",
        "gauge",
        "Current round size in rows",
        s.window.load(Relaxed),
    );
    put(
        "shard_commits_total",
        "counter",
        "Shard commits",
        s.commits.load(Relaxed),
    );
    put(
        "writers_open",
        "gauge",
        "Open shard writers",
        s.writers_open.load(Relaxed),
    );
    put(
        "skipped_stale_total",
        "counter",
        "Out-of-order note ops skipped",
        s.skipped_stale.load(Relaxed),
    );
    put(
        "filled_stale_total",
        "counter",
        "Out-of-order upserts applied for kept points",
        s.filled_stale.load(Relaxed),
    );
    put(
        "skipped_tombstoned_total",
        "counter",
        "Upserts dropped for a deleted user or vault",
        s.skipped_tomb.load(Relaxed),
    );
    put(
        "skipped_generation_total",
        "counter",
        "Rows for a generation this node does not hold",
        s.skipped_gen.load(Relaxed),
    );
    put(
        "skipped_malformed_total",
        "counter",
        "Feed rows skipped as malformed (ragged terms, missing note or vault)",
        s.skipped_malformed.load(Relaxed),
    );
    put(
        "purges_total",
        "counter",
        "Purge merges of segments holding deletes",
        s.purges.load(Relaxed),
    );
    put(
        "restored_deletes",
        "gauge",
        "Deletion-log deletes applied at boot",
        s.restored_deletes.load(Relaxed),
    );
    put(
        "searches_total",
        "counter",
        "Searches answered",
        s.searches.load(Relaxed),
    );
    put(
        "search_errors_total",
        "counter",
        "Searches that failed inside the index",
        s.search_errors.load(Relaxed),
    );
    put(
        "unauthorized_total",
        "counter",
        "Requests with a missing or invalid token",
        s.unauthorized.load(Relaxed),
    );
    let oldest = index.all().filter_map(|x| x.first_delete_at()).min();
    put(
        "oldest_unpurged_delete_seconds",
        "gauge",
        "Age of the oldest delete whose bytes are still on disk",
        oldest.map_or(0, |t| now().saturating_sub(t)),
    );
    put("rss_bytes", "gauge", "Resident set size", rss_bytes());
    let _ = writeln!(
        o,
        "# HELP kwsearch_shard_segments Segments per shard\n# TYPE kwsearch_shard_segments gauge"
    );
    let mut deleted = String::new();
    for (gen, shards) in &index.gens {
        for (i, sh) in shards.shards.iter().enumerate() {
            let (segs, del) = sh.segment_stats();
            let _ = writeln!(
                o,
                "kwsearch_shard_segments{{gen=\"{gen}\",shard=\"{i}\"}} {segs}"
            );
            let _ = writeln!(
                deleted,
                "kwsearch_shard_deleted_docs{{gen=\"{gen}\",shard=\"{i}\"}} {del}"
            );
        }
    }
    let _ = writeln!(o, "# HELP kwsearch_shard_deleted_docs Deleted docs not yet merged away\n# TYPE kwsearch_shard_deleted_docs gauge");
    o.push_str(&deleted);
    o
}

fn rss_bytes() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("VmRSS:"))
                .and_then(|l| l.split_whitespace().nth(1)?.parse::<u64>().ok())
        })
        .map_or(0, |kb| kb * 1024)
}
