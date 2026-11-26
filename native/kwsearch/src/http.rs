//! HTTP/1.1 (keep-alive) API: POST /search, GET /health.

use crate::feed::{Shards, Stats};
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::atomic::Ordering::Relaxed;
use std::sync::Arc;
use std::time::Instant;
use uuid::Uuid;

/// Same cap as `NoteFilter`'s id lists.
pub const MAX_IDS: usize = 10_240;
/// `Qdrant.max_page()`: the `:too_wide` oversample reads up to this many.
pub const MAX_LIMIT: usize = 4_096;

#[derive(Clone)]
pub struct App {
    pub shards: Arc<Shards>,
    pub stats: Arc<Stats>,
    pub secret: Arc<String>,
}

#[derive(Deserialize)]
pub struct SearchReq {
    user: Uuid,
    vaults: Vec<Uuid>,
    terms: Vec<u32>,
    /// Note-id filters as JSON UUID strings...
    #[serde(default)]
    include: Option<Vec<Uuid>>,
    #[serde(default)]
    exclude: Vec<Uuid>,
    /// ...or compact: base64 of the concatenated 16-byte ids.
    #[serde(default)]
    include_b64: Option<String>,
    #[serde(default)]
    exclude_b64: Option<String>,
    limit: usize,
    /// POC only: Tantivy's shard-wide BM25 statistics instead of per-user.
    #[serde(default)]
    shard_stats: bool,
}

fn ids_b64(s: &str) -> Result<Vec<Uuid>, String> {
    let b = base64::engine::general_purpose::STANDARD.decode(s).map_err(|e| e.to_string())?;
    if !b.len().is_multiple_of(16) {
        return Err("id list is not a multiple of 16 bytes".into());
    }
    Ok(b.chunks_exact(16).map(|c| Uuid::from_slice(c).unwrap()).collect())
}

fn bad(msg: impl Into<String>) -> (StatusCode, Json<Value>) {
    (StatusCode::BAD_REQUEST, Json(json!({"error": msg.into()})))
}

/// Constant time, so the shared secret does not leak through timing.
fn authorized(h: &HeaderMap, secret: &str) -> bool {
    let want = format!("Bearer {secret}");
    let got = h.get("authorization").map(|v| v.as_bytes()).unwrap_or_default();
    got.len() == want.len() && got.iter().zip(want.as_bytes()).fold(0u8, |a, (x, y)| a | (x ^ y)) == 0
}

async fn search(State(app): State<App>, h: HeaderMap, Json(r): Json<SearchReq>) -> (StatusCode, Json<Value>) {
    if !authorized(&h, &app.secret) {
        return (StatusCode::UNAUTHORIZED, Json(json!({"error": "unauthorized"})));
    }
    let include = match (r.include, r.include_b64) {
        (Some(v), None) => Some(v),
        (None, Some(s)) => match ids_b64(&s) {
            Ok(v) => Some(v),
            Err(e) => return bad(e),
        },
        (None, None) => None,
        _ => return bad("include and include_b64 are exclusive"),
    };
    let mut exclude = r.exclude;
    if let Some(s) = r.exclude_b64 {
        match ids_b64(&s) {
            Ok(v) => exclude.extend(v),
            Err(e) => return bad(e),
        }
    }
    if include.as_ref().is_some_and(|v| v.len() > MAX_IDS) || exclude.len() > MAX_IDS {
        return bad(format!("at most {MAX_IDS} note ids per list"));
    }
    if r.vaults.is_empty() || r.limit == 0 || r.limit > MAX_LIMIT {
        return bad(format!("need >= 1 vault and 1 <= limit <= {MAX_LIMIT}"));
    }
    let t0 = Instant::now();
    let shards = app.shards.clone();
    let res = tokio::task::spawn_blocking(move || {
        shards.of(&r.user).search(&r.user, &r.vaults, &r.terms, include.as_deref(), &exclude, r.limit, r.shard_stats)
    })
    .await
    .unwrap();
    match res {
        Ok(hits) => {
            let hits: Vec<Value> = hits.iter().map(|(p, s)| json!([p.to_string(), s])).collect();
            (StatusCode::OK, Json(json!({"hits": hits, "took_us": t0.elapsed().as_micros() as u64})))
        }
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": e.to_string()}))),
    }
}

pub fn proc_stats() -> Value {
    let status = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
    let kb = |k: &str| {
        status
            .lines()
            .find(|l| l.starts_with(k))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|v| v.parse::<u64>().ok())
    };
    let count = |p: &str| std::fs::read_dir(p).map(|d| d.count()).unwrap_or(0);
    let maps = std::fs::read_to_string("/proc/self/maps").map(|m| m.lines().count()).unwrap_or(0);
    json!({"rss_kb": kb("VmRSS:"), "hwm_kb": kb("VmHWM:"), "anon_kb": kb("RssAnon:"), "file_kb": kb("RssFile:"), "threads": kb("Threads:"),
           "fds": count("/proc/self/fd"), "maps": maps})
}

async fn health(State(app): State<App>) -> Json<Value> {
    let s = &app.stats;
    let segments: usize = app.shards.shards.iter().map(|x| x.reader.searcher().segment_readers().len()).sum();
    Json(json!({
        "up": true,
        "cursor_xid": s.cursor_xid.load(Relaxed),
        "rows": s.rows.load(Relaxed),
        "rounds": s.rounds.load(Relaxed),
        "commits": s.commits.load(Relaxed),
        "writers_open": s.writers_open.load(Relaxed),
        "writers_peak": s.writers_peak.load(Relaxed),
        "skipped_stale": s.skipped_stale.load(Relaxed),
        "filled_stale": s.filled_stale.load(Relaxed),
        "apply_ms": s.apply_ms.load(Relaxed),
        "commit_ms": s.commit_ms.load(Relaxed),
        "close_ms": s.close_ms.load(Relaxed),
        "skipped_tomb": s.skipped_tomb.load(Relaxed),
        "segments": segments,
        "proc": proc_stats(),
    }))
}

pub fn router(app: App) -> Router {
    Router::new()
        .route("/search", post(search))
        .route("/health", get(health))
        .layer(axum::extract::DefaultBodyLimit::max(2 << 20))
        .with_state(app)
}
