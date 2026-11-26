//! HTTPS (HTTP/1.1 keep-alive) API: POST /search, /bulk, /notes, /rebuilt,
//! GET /health, /metrics, /cursor.
//!
//! Every search needs a signed token naming the user and the vaults
//! (`token`); the body cannot widen them. `/bulk` and `/notes` take the user
//! from a bulk token the same way. Error bodies are fixed strings, never
//! internals (security F15).

use crate::feed::{now, Index, Stats};
use crate::shard::{BulkNote, BULK_MAX_AGE_S};
use crate::token::{Claims, Keys};
use axum::extract::State;
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::Engine;
use serde::Deserialize;
use serde_json::json;
use std::sync::atomic::Ordering::Relaxed;
use std::sync::Arc;
use uuid::Uuid;

/// Same cap as `NoteFilter`'s id lists.
pub const MAX_IDS: usize = 10_240;
/// `Qdrant.max_page()`: the `:too_wide` oversample reads up to this many.
pub const MAX_LIMIT: usize = 4_096;
/// Query terms per search (a query is a handful of words; this bounds work).
pub const MAX_TERMS: usize = 1_024;
/// Notes per bulk request, and per `/notes` page.
pub const MAX_BULK_NOTES: usize = 1_000;
pub const MAX_NOTES_PAGE: usize = 10_000;
/// A bulk body (the app sends ~2 MB batches; one huge note may go alone).
pub const MAX_BULK_BYTES: usize = 16 << 20;
/// A bulk batch's read time may run this far ahead of this node's clock.
pub const CLOCK_SKEW_S: u64 = 300;

#[derive(Clone)]
pub struct App {
    pub index: Arc<Index>,
    pub stats: Arc<Stats>,
    pub keys: Arc<Keys>,
    pub metrics_token: Arc<String>,
    pub writer_mb: usize,
    pub tomb_ttl_s: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SearchReq {
    #[serde(default = "one")]
    gen: i16,
    terms: Vec<u32>,
    limit: usize,
    /// Note-id filters: base64 of the concatenated raw 16-byte ids.
    #[serde(default)]
    include_b64: Option<String>,
    #[serde(default)]
    exclude_b64: Option<String>,
}

fn one() -> i16 {
    1
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BulkReq {
    #[serde(default = "one")]
    gen: i16,
    /// Unix seconds the app read the batch's rows (under the note locks).
    read_at: u64,
    notes: Vec<BulkNoteReq>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BulkNoteReq {
    vault: Uuid,
    note: Uuid,
    stamp: i64,
    xmax: u64,
    /// The note's full point set: base64 of the raw 16-byte ids.
    keep_b64: String,
    docs: Vec<BulkDocReq>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BulkDocReq {
    point: Uuid,
    /// kwfeed codec, base64.
    terms_b64: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NotesReq {
    #[serde(default = "one")]
    gen: i16,
    #[serde(default)]
    after: Option<Uuid>,
    limit: usize,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RebuiltReq {
    epoch: String,
}

fn ids_b64(s: &str) -> Option<Vec<Uuid>> {
    ids_b64_max(s, MAX_IDS)
}

fn ids_b64_max(s: &str, max: usize) -> Option<Vec<Uuid>> {
    let b = base64::engine::general_purpose::STANDARD.decode(s).ok()?;
    if !b.len().is_multiple_of(16) || b.len() / 16 > max {
        return None;
    }
    Some(
        b.chunks_exact(16)
            .map(|c| Uuid::from_slice(c).unwrap())
            .collect(),
    )
}

fn err(code: StatusCode, msg: &'static str) -> Response {
    (code, Json(json!({ "error": msg }))).into_response()
}

fn bearer(h: &HeaderMap) -> Option<&str> {
    h.get(header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
}

/// Constant time, so a static token does not leak through timing.
fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

async fn search(State(app): State<App>, h: HeaderMap, body: axum::body::Bytes) -> Response {
    let claims = bearer(&h).and_then(|t| app.keys.verify(t, now()));
    let Some(Claims::Search {
        u: user, v: vaults, ..
    }) = claims
    else {
        app.stats.unauthorized.fetch_add(1, Relaxed);
        return err(StatusCode::UNAUTHORIZED, "unauthorized");
    };
    if !app.stats.ready.load(Relaxed) {
        return err(StatusCode::SERVICE_UNAVAILABLE, "not_ready");
    }
    let Ok(r) = serde_json::from_slice::<SearchReq>(&body) else {
        return err(StatusCode::BAD_REQUEST, "bad_request");
    };
    let include = match r.include_b64.as_deref().map(ids_b64) {
        Some(None) => return err(StatusCode::BAD_REQUEST, "bad_request"),
        other => other.flatten(),
    };
    let exclude = match r.exclude_b64.as_deref().map(ids_b64) {
        Some(None) => return err(StatusCode::BAD_REQUEST, "bad_request"),
        other => other.flatten().unwrap_or_default(),
    };
    if vaults.is_empty() || r.limit == 0 || r.limit > MAX_LIMIT || r.terms.len() > MAX_TERMS {
        return err(StatusCode::BAD_REQUEST, "bad_request");
    }
    let Some(gen) = app.index.gens.contains_key(&r.gen).then_some(r.gen) else {
        return err(StatusCode::BAD_REQUEST, "bad_request");
    };
    if r.terms.is_empty() {
        return Json(json!({ "hits": [] })).into_response();
    }
    let index = app.index.clone();
    let res = tokio::task::spawn_blocking(move || {
        index.gens[&gen].of(&user).search(
            &user,
            &vaults,
            &r.terms,
            include.as_deref(),
            &exclude,
            r.limit,
        )
    })
    .await;
    app.stats.searches.fetch_add(1, Relaxed);
    match res {
        Ok(Ok(hits)) => {
            let hits: Vec<_> = hits
                .iter()
                .map(|(p, s)| json!([p.to_string(), s]))
                .collect();
            Json(json!({ "hits": hits })).into_response()
        }
        _ => {
            app.stats.search_errors.fetch_add(1, Relaxed);
            err(StatusCode::INTERNAL_SERVER_ERROR, "internal")
        }
    }
}

fn bulk_user(app: &App, h: &HeaderMap) -> Option<Uuid> {
    match bearer(h).and_then(|t| app.keys.verify(t, now())) {
        Some(Claims::Bulk { u, .. }) => Some(u),
        _ => {
            app.stats.unauthorized.fetch_add(1, Relaxed);
            None
        }
    }
}

/// One user's bulk batch (backfill, reconcile). Accepted while the node is
/// rebuilding: it is how a rebuild happens. Ordering and tombstone checks
/// are per note in `Shard::bulk`; the age bound is here.
async fn bulk(State(app): State<App>, h: HeaderMap, body: axum::body::Bytes) -> Response {
    let Some(user) = bulk_user(&app, &h) else {
        return err(StatusCode::UNAUTHORIZED, "unauthorized");
    };
    let Ok(r) = serde_json::from_slice::<BulkReq>(&body) else {
        return err(StatusCode::BAD_REQUEST, "bad_request");
    };
    let now = now();
    if r.notes.len() > MAX_BULK_NOTES || r.read_at > now + CLOCK_SKEW_S {
        return err(StatusCode::BAD_REQUEST, "bad_request");
    }
    if r.read_at + BULK_MAX_AGE_S < now {
        return err(StatusCode::CONFLICT, "stale_batch");
    }
    if !app.index.gens.contains_key(&r.gen) {
        return err(StatusCode::BAD_REQUEST, "bad_request");
    }
    let b64 = base64::engine::general_purpose::STANDARD;
    let mut notes = Vec::with_capacity(r.notes.len());
    for n in r.notes {
        let Some(keep) = ids_b64_max(&n.keep_b64, usize::MAX) else {
            return err(StatusCode::BAD_REQUEST, "bad_request");
        };
        let mut docs = Vec::with_capacity(n.docs.len());
        for d in n.docs {
            let Ok(t) = b64.decode(d.terms_b64) else {
                return err(StatusCode::BAD_REQUEST, "bad_request");
            };
            docs.push((d.point, t));
        }
        notes.push(BulkNote {
            vault: n.vault,
            note: n.note,
            stamp: n.stamp,
            xmax: n.xmax,
            keep,
            docs,
        });
    }
    let index = app.index.clone();
    let ttl = app.tomb_ttl_s;
    let res = tokio::task::spawn_blocking(move || {
        let s = index.gens[&r.gen].of(&user);
        let a = s.bulk(&user, r.gen, &notes, app.writer_mb, now)?;
        s.commit_here(now, ttl)?;
        Ok::<_, tantivy::TantivyError>(a)
    })
    .await;
    match res {
        Ok(Ok(a)) => {
            app.stats.skipped_stale.fetch_add(a.skipped_stale, Relaxed);
            app.stats.skipped_tomb.fetch_add(a.skipped_tomb, Relaxed);
            app.stats
                .skipped_malformed
                .fetch_add(a.skipped_malformed, Relaxed);
            app.stats.bulk_notes.fetch_add(a.applied, Relaxed);
            Json(json!({
                "applied": a.applied,
                "stale": a.skipped_stale,
                "tomb": a.skipped_tomb,
                "malformed": a.skipped_malformed,
            }))
            .into_response()
        }
        _ => err(StatusCode::INTERNAL_SERVER_ERROR, "internal"),
    }
}

/// A user's indexed notes with their chunk doc counts, by note id, after
/// `after` (the reconcile's drift check and orphan pass).
async fn notes(State(app): State<App>, h: HeaderMap, body: axum::body::Bytes) -> Response {
    let Some(user) = bulk_user(&app, &h) else {
        return err(StatusCode::UNAUTHORIZED, "unauthorized");
    };
    let Ok(r) = serde_json::from_slice::<NotesReq>(&body) else {
        return err(StatusCode::BAD_REQUEST, "bad_request");
    };
    if r.limit == 0 || r.limit > MAX_NOTES_PAGE || !app.index.gens.contains_key(&r.gen) {
        return err(StatusCode::BAD_REQUEST, "bad_request");
    }
    let index = app.index.clone();
    let res = tokio::task::spawn_blocking(move || {
        index.gens[&r.gen].of(&user).notes(&user, r.after, r.limit)
    })
    .await;
    match res {
        Ok(Ok(list)) => {
            let notes: Vec<_> = list.iter().map(|(n, v, c)| json!([n, v, c])).collect();
            Json(json!({ "notes": notes })).into_response()
        }
        _ => err(StatusCode::INTERNAL_SERVER_ERROR, "internal"),
    }
}

/// The app's reconcile loaded every user for `epoch`: the node may serve
/// once the feed is drained (ops token).
async fn rebuilt(State(app): State<App>, h: HeaderMap, body: axum::body::Bytes) -> Response {
    if !matches!(
        bearer(&h).and_then(|t| app.keys.verify(t, now())),
        Some(Claims::Ops { .. })
    ) {
        return err(StatusCode::UNAUTHORIZED, "unauthorized");
    }
    let Ok(r) = serde_json::from_slice::<RebuiltReq>(&body) else {
        return err(StatusCode::BAD_REQUEST, "bad_request");
    };
    match app.index.finish_rebuild(&r.epoch) {
        Ok(true) => {
            app.stats.gap.store(false, Relaxed);
            eprintln!("epoch {} rebuilt", r.epoch);
            Json(json!({ "ok": true })).into_response()
        }
        Ok(false) => err(StatusCode::CONFLICT, "other_epoch"),
        Err(_) => err(StatusCode::INTERNAL_SERVER_ERROR, "internal"),
    }
}

/// No auth, exactly two fields (F15). `up` is false while booting or
/// restoring, and after a feed gap.
async fn health(State(app): State<App>) -> Response {
    let up = app.stats.ready.load(Relaxed);
    let code = if up {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    (code, Json(json!({ "up": up, "lag_s": app.stats.lag_s() }))).into_response()
}

/// The applied cursor, for the feed trim (ops token).
async fn cursor(State(app): State<App>, h: HeaderMap) -> Response {
    match bearer(&h).and_then(|t| app.keys.verify(t, now())) {
        Some(Claims::Ops { .. }) => {
            let e = app.index.epoch();
            Json(json!({
                "xid": app.stats.cursor_xid.load(Relaxed).to_string(),
                "seq": app.stats.cursor_seq.load(Relaxed),
                "epoch": e.id,
                "rebuilding": e.rebuilding,
            }))
            .into_response()
        }
        _ => err(StatusCode::UNAUTHORIZED, "unauthorized"),
    }
}

async fn metrics(State(app): State<App>, h: HeaderMap) -> Response {
    let ok = bearer(&h).is_some_and(|t| same(t.as_bytes(), app.metrics_token.as_bytes()));
    if !ok {
        return err(StatusCode::UNAUTHORIZED, "unauthorized");
    }
    let index = app.index.clone();
    let stats = app.stats.clone();
    let text = tokio::task::spawn_blocking(move || crate::metrics::render(&index, &stats))
        .await
        .unwrap_or_default();
    ([(header::CONTENT_TYPE, "text/plain; version=0.0.4")], text).into_response()
}

pub fn router(app: App) -> Router {
    Router::new()
        .route("/search", post(search))
        .route("/health", get(health))
        .route("/cursor", get(cursor))
        .route("/metrics", get(metrics))
        .route("/notes", post(notes))
        .route("/rebuilt", post(rebuilt))
        .layer(axum::extract::DefaultBodyLimit::max(2 << 20))
        .route(
            "/bulk",
            post(bulk).layer(axum::extract::DefaultBodyLimit::max(MAX_BULK_BYTES)),
        )
        .with_state(app)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::row::Row;
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;

    const KEY: &str = "0123456789abcdef0123456789abcdef-current";
    const METRICS: &str = "metrics-token-0123456789abcdef0123456789";

    fn uid(n: u64) -> Uuid {
        Uuid::from_u64_pair(0x77, n)
    }

    fn app(dir: &std::path::Path) -> (App, Router) {
        let index = Arc::new(Index::open(dir, &[1]).unwrap());
        let a = App {
            index,
            stats: Arc::new(Stats::default()),
            keys: Arc::new(Keys::parse(KEY).unwrap()),
            metrics_token: Arc::new(METRICS.into()),
            writer_mb: 15,
            tomb_ttl_s: 86_400,
        };
        (a.clone(), router(a))
    }

    fn tok(p: serde_json::Value) -> String {
        let mut p = p;
        p["exp"] = json!(now() + 60);
        crate::token::sign(KEY.as_bytes(), &p.to_string())
    }

    async fn call(r: &Router, req: Request<Body>) -> (StatusCode, String) {
        let res = r.clone().oneshot(req).await.unwrap();
        let code = res.status();
        let b = axum::body::to_bytes(res.into_body(), 1 << 20)
            .await
            .unwrap();
        (code, String::from_utf8(b.to_vec()).unwrap())
    }

    fn search_req(token: Option<&str>, body: serde_json::Value) -> Request<Body> {
        let mut b = Request::post("/search").header("content-type", "application/json");
        if let Some(t) = token {
            b = b.header("authorization", format!("Bearer {t}"));
        }
        b.body(Body::from(body.to_string())).unwrap()
    }

    /// Two users in their own shards, one doc each on the same dim.
    fn seed(a: &App) -> (Uuid, Uuid, Uuid, Uuid) {
        let (ua, ub, va, vb) = (uid(1), uid(2), uid(3), uid(4));
        for (i, (u, v)) in [(ua, va), (ub, vb)].into_iter().enumerate() {
            let r = Row {
                seq: i as i64 + 1,
                xid: 1,
                xmax: 2,
                user: u,
                gen: 1,
                op: kwfeed::UPSERT,
                vault: Some(v),
                note: Some(uid(10 + i as u64)),
                point: Some(uid(20 + i as u64)),
                stamp: 1,
                terms: Some(kwfeed::pack([(7, 1)])),
                keep: None,
            };
            let s = a.index.gens[&1].of(&u);
            s.apply(&[&r], 15, now()).unwrap();
            s.commit((1, r.seq), 0, now(), 86_400).unwrap();
        }
        (ua, ub, va, vb)
    }

    #[tokio::test]
    async fn search_needs_a_token_and_takes_user_and_vaults_from_it() {
        let dir = crate::shard_tests::tmp();
        let (a, r) = app(dir.path());
        let (ua, ub, va, vb) = seed(&a);
        let body = json!({"terms": [7], "limit": 10});
        assert_eq!(
            call(&r, search_req(None, body.clone())).await.0,
            StatusCode::UNAUTHORIZED
        );
        let forged = crate::token::sign(
            b"another-key-0123456789abcdef0123456789",
            &json!({"s":"search","u":ua,"v":[va],"exp":now()+60}).to_string(),
        );
        assert_eq!(
            call(&r, search_req(Some(&forged), body.clone())).await.0,
            StatusCode::UNAUTHORIZED
        );
        let t = tok(json!({"s": "search", "u": ua, "v": [va]}));
        assert_eq!(
            call(&r, search_req(Some(&t), body.clone())).await.0,
            StatusCode::SERVICE_UNAVAILABLE
        );
        a.stats.ready.store(true, Relaxed);
        let (code, out) = call(&r, search_req(Some(&t), body.clone())).await;
        assert_eq!(code, StatusCode::OK);
        assert!(out.contains(&uid(20).to_string()) && !out.contains(&uid(21).to_string()));
        // A's token naming B's vault returns nothing; a body cannot name a user.
        let t = tok(json!({"s": "search", "u": ua, "v": [vb]}));
        assert_eq!(
            call(&r, search_req(Some(&t), body.clone())).await.1,
            r#"{"hits":[]}"#
        );
        let widened = json!({"terms": [7], "limit": 10, "user": ub, "vaults": [vb]});
        assert_eq!(
            call(&r, search_req(Some(&t), widened)).await.0,
            StatusCode::BAD_REQUEST
        );
        let ops = tok(json!({"s": "ops"}));
        assert_eq!(
            call(&r, search_req(Some(&ops), body)).await.0,
            StatusCode::UNAUTHORIZED
        );
    }

    #[tokio::test]
    async fn bad_requests_get_fixed_error_bodies() {
        let dir = crate::shard_tests::tmp();
        let (a, r) = app(dir.path());
        a.stats.ready.store(true, Relaxed);
        let t = tok(json!({"s": "search", "u": uid(1), "v": [uid(3)]}));
        for body in [
            json!({"terms": [1], "limit": 0}),
            json!({"terms": [1], "limit": 5000}),
            json!({"terms": [1], "limit": 5, "include_b64": "%%%"}),
            json!({"terms": [1], "limit": 5, "exclude_b64": "AAAA"}),
            json!({"terms": [1], "limit": 5, "gen": 2}),
        ] {
            assert_eq!(
                call(&r, search_req(Some(&t), body)).await,
                (StatusCode::BAD_REQUEST, r#"{"error":"bad_request"}"#.into())
            );
        }
    }

    // F15: /health holds exactly two fields; /metrics needs its token and
    // labels by shard, never by user; /cursor needs an ops token.
    #[tokio::test]
    async fn health_metrics_and_cursor_surfaces() {
        let dir = crate::shard_tests::tmp();
        let (a, r) = app(dir.path());
        let (ua, ..) = seed(&a);
        let (code, body) = call(&r, Request::get("/health").body(Body::empty()).unwrap()).await;
        assert_eq!(code, StatusCode::SERVICE_UNAVAILABLE);
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(
            v.as_object().unwrap().keys().collect::<Vec<_>>(),
            ["lag_s", "up"]
        );
        let get = |path: &str, t: Option<&str>| {
            let mut b = Request::get(path);
            if let Some(t) = t {
                b = b.header("authorization", format!("Bearer {t}"));
            }
            b.body(Body::empty()).unwrap()
        };
        assert_eq!(
            call(&r, get("/metrics", None)).await.0,
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            call(&r, get("/metrics", Some("wrong"))).await.0,
            StatusCode::UNAUTHORIZED
        );
        let (code, text) = call(&r, get("/metrics", Some(METRICS))).await;
        assert_eq!(code, StatusCode::OK);
        assert!(text.contains("kwsearch_shard_segments{gen=\"1\",shard=\""));
        for u in [ua.to_string(), ua.simple().to_string()] {
            assert!(!text.contains(&u), "a metric names a user");
        }
        assert_eq!(
            call(&r, get("/cursor", Some(METRICS))).await.0,
            StatusCode::UNAUTHORIZED
        );
        let search = tok(json!({"s": "search", "u": ua, "v": []}));
        assert_eq!(
            call(&r, get("/cursor", Some(&search))).await.0,
            StatusCode::UNAUTHORIZED
        );
        a.stats.cursor_xid.store(42, Relaxed);
        a.stats.cursor_seq.store(7, Relaxed);
        let ops = tok(json!({"s": "ops"}));
        let v: serde_json::Value =
            serde_json::from_str(&call(&r, get("/cursor", Some(&ops))).await.1).unwrap();
        assert_eq!(
            (v["xid"].as_str(), v["seq"].as_u64()),
            (Some("42"), Some(7))
        );
        assert_eq!(v["epoch"].as_str(), Some(a.index.epoch().id.as_str()));
        assert_eq!(
            v["rebuilding"],
            json!(true),
            "a new index starts rebuilding"
        );
    }

    fn post(path: &str, token: &str, body: serde_json::Value) -> Request<Body> {
        Request::post(path)
            .header("content-type", "application/json")
            .header("authorization", format!("Bearer {token}"))
            .body(Body::from(body.to_string()))
            .unwrap()
    }

    fn b64(bytes: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    fn bulk_body(read_at: u64, vault: Uuid, note: Uuid, point: Uuid) -> serde_json::Value {
        json!({"read_at": read_at, "notes": [{
            "vault": vault, "note": note, "stamp": 1, "xmax": 2,
            "keep_b64": b64(point.as_bytes()),
            "docs": [{"point": point, "terms_b64": b64(&kwfeed::pack([(7, 1)]))}]
        }]})
    }

    // Task 5: the batch age bound, and the tenant from the bulk token only.
    #[tokio::test]
    async fn bulk_takes_the_user_from_its_token_and_refuses_old_batches() {
        let dir = crate::shard_tests::tmp();
        let (a, r) = app(dir.path());
        a.stats.ready.store(true, Relaxed);
        let (ua, va, note, point) = (uid(1), uid(3), uid(10), uid(20));
        let body = bulk_body(now(), va, note, point);
        let search = tok(json!({"s": "search", "u": ua, "v": [va]}));
        assert_eq!(
            call(&r, post("/bulk", &search, body.clone())).await.0,
            StatusCode::UNAUTHORIZED,
            "a search token cannot write"
        );
        let bulk = tok(json!({"s": "bulk", "u": ua}));
        let old = bulk_body(now() - BULK_MAX_AGE_S - 1, va, note, point);
        assert_eq!(
            call(&r, post("/bulk", &bulk, old)).await,
            (StatusCode::CONFLICT, r#"{"error":"stale_batch"}"#.into())
        );
        let ahead = bulk_body(now() + CLOCK_SKEW_S + 60, va, note, point);
        assert_eq!(
            call(&r, post("/bulk", &bulk, ahead)).await.0,
            StatusCode::BAD_REQUEST
        );
        let mut widened = body.clone();
        widened["user"] = json!(uid(2));
        assert_eq!(
            call(&r, post("/bulk", &bulk, widened)).await.0,
            StatusCode::BAD_REQUEST
        );
        let (code, out) = call(&r, post("/bulk", &bulk, body)).await;
        assert_eq!(code, StatusCode::OK);
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&out).unwrap()["applied"],
            1
        );
        let t = tok(json!({"s": "search", "u": ua, "v": [va]}));
        let (_, hits) = call(&r, search_req(Some(&t), json!({"terms": [7], "limit": 5}))).await;
        assert!(hits.contains(&point.to_string()));
        let (_, listed) = call(&r, post("/notes", &bulk, json!({"limit": 10}))).await;
        assert_eq!(listed, format!(r#"{{"notes":[["{note}","{va}",1]]}}"#));
        let other = tok(json!({"s": "bulk", "u": uid(2)}));
        let (_, listed) = call(&r, post("/notes", &other, json!({"limit": 10}))).await;
        assert_eq!(
            listed, r#"{"notes":[]}"#,
            "another user's token lists nothing of A's"
        );
    }

    // A new index (or one after a feed gap) is rebuilding until the app says
    // it loaded THIS epoch; an older epoch's claim is refused.
    #[tokio::test]
    async fn rebuilt_clears_only_the_current_epoch() {
        let dir = crate::shard_tests::tmp();
        let (a, r) = app(dir.path());
        let ops = tok(json!({"s": "ops"}));
        let e = a.index.epoch();
        assert!(e.rebuilding);
        assert_eq!(
            call(&r, post("/rebuilt", &ops, json!({"epoch": "stale"})))
                .await
                .0,
            StatusCode::CONFLICT
        );
        let bulk = tok(json!({"s": "bulk", "u": uid(1)}));
        assert_eq!(
            call(&r, post("/rebuilt", &bulk, json!({"epoch": e.id})))
                .await
                .0,
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            call(&r, post("/rebuilt", &ops, json!({"epoch": e.id})))
                .await
                .0,
            StatusCode::OK
        );
        assert!(!a.index.epoch().rebuilding);
        // Persisted: a restart keeps the epoch and its state.
        let reopened = Index::open(dir.path(), &[1]).unwrap();
        assert_eq!(reopened.epoch(), a.index.epoch());
        // A gap starts a new epoch, rebuilding again.
        let next = a.index.begin_rebuild().unwrap();
        assert!(next.rebuilding && next.id != e.id);
    }
}
