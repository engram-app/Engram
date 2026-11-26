//! HTTPS (HTTP/1.1 keep-alive) API: POST /search, GET /health, /metrics, /cursor.
//!
//! Every search needs a signed token naming the user and the vaults
//! (`token`); the body cannot widen them. Error bodies are fixed strings,
//! never internals (security F15).

use crate::feed::{now, Index, Stats};
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

#[derive(Clone)]
pub struct App {
    pub index: Arc<Index>,
    pub stats: Arc<Stats>,
    pub keys: Arc<Keys>,
    pub metrics_token: Arc<String>,
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

fn ids_b64(s: &str) -> Option<Vec<Uuid>> {
    let b = base64::engine::general_purpose::STANDARD.decode(s).ok()?;
    if !b.len().is_multiple_of(16) || b.len() / 16 > MAX_IDS {
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
        Some(Claims::Ops { .. }) => Json(json!({
            "xid": app.stats.cursor_xid.load(Relaxed).to_string(),
            "seq": app.stats.cursor_seq.load(Relaxed),
        }))
        .into_response(),
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
        .layer(axum::extract::DefaultBodyLimit::max(2 << 20))
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
        assert_eq!(
            call(&r, get("/cursor", Some(&ops))).await.1,
            r#"{"seq":7,"xid":"42"}"#
        );
    }
}
