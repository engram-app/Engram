//! POC tools: schema, workload generators, verify, bench, the xid test.
//! Run against a THROWAWAY Postgres only.

use crate::shard::{fnv, shard_of, Shard, SHARDS};
use crate::{env, env_n};
use base64::Engine;
use postgres::{Client, NoTls, Transaction};
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::time::{Duration, Instant};
use uuid::Uuid;

pub fn run(cmd: &str, args: &[String]) {
    match cmd {
        "schema" => schema(),
        "gen" => gen(),
        "burst" => burst(),
        "load-eval" => load_eval(),
        "verify" => verify(),
        "bench" => bench(args),
        "xidtest" => xidtest(),
        "du" => du(),
        _ => panic!("unknown command {cmd}"),
    }
}

fn db() -> Client {
    Client::connect(&env("KW_SUPER_URL", ""), NoTls).expect("connect KW_SUPER_URL")
}

/// The roadmap's feed table and reader role (R3 + PR 284 review), plus the
/// generator's truth tables (what the index must equal at the end).
fn schema() {
    let feed_pw = std::fs::read_to_string(env("KW_FEED_PW_FILE", "/secrets/feedpw")).unwrap();
    let mut c = db();
    c.batch_execute(
        "CREATE TABLE IF NOT EXISTS keyword_feed (
           seq bigserial PRIMARY KEY,
           xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
           user_id uuid NOT NULL,
           index_set smallint NOT NULL DEFAULT 1,
           op smallint NOT NULL,
           vault_id uuid, note_id uuid, point_id uuid,
           stamp bigint NOT NULL DEFAULT 0,
           terms bytea,
           keep uuid[]);
         CREATE INDEX IF NOT EXISTS keyword_feed_xid_seq ON keyword_feed (xid, seq);
         ALTER TABLE keyword_feed ENABLE ROW LEVEL SECURITY;
         ALTER TABLE keyword_feed FORCE ROW LEVEL SECURITY;
         CREATE TABLE IF NOT EXISTS truth_users (user_id uuid PRIMARY KEY, dead bool NOT NULL DEFAULT false);
         CREATE TABLE IF NOT EXISTS truth_vaults (vault_id uuid PRIMARY KEY, user_id uuid NOT NULL, dead bool NOT NULL DEFAULT false);
         CREATE TABLE IF NOT EXISTS truth_notes (note_id uuid PRIMARY KEY, user_id uuid NOT NULL, vault_id uuid NOT NULL, stamp bigint NOT NULL);
         CREATE TABLE IF NOT EXISTS truth_chunks (point_id uuid PRIMARY KEY, user_id uuid NOT NULL, vault_id uuid NOT NULL,
           note_id uuid NOT NULL, terms bytea NOT NULL);
         CREATE INDEX IF NOT EXISTS truth_chunks_note ON truth_chunks (note_id);
         CREATE INDEX IF NOT EXISTS truth_chunks_vault ON truth_chunks (vault_id);
         CREATE INDEX IF NOT EXISTS truth_chunks_user ON truth_chunks (user_id);",
    )
    .unwrap();
    let exists = c.query_opt("SELECT 1 FROM pg_roles WHERE rolname = 'kwsearch_feed'", &[]).unwrap().is_some();
    if !exists {
        c.batch_execute("CREATE ROLE kwsearch_feed NOINHERIT LOGIN CONNECTION LIMIT 4").unwrap();
    }
    // Password per boot, the way release.ex applies engram_maintenance's.
    c.batch_execute(&format!("ALTER ROLE kwsearch_feed PASSWORD '{}'", feed_pw.trim().replace('\'', "''")))
        .unwrap();
    c.batch_execute(
        "ALTER ROLE kwsearch_feed SET statement_timeout = '30s';
         GRANT USAGE ON SCHEMA public TO kwsearch_feed;
         GRANT SELECT ON keyword_feed TO kwsearch_feed;
         DROP POLICY IF EXISTS kwsearch_feed_read ON keyword_feed;
         CREATE POLICY kwsearch_feed_read ON keyword_feed FOR SELECT TO kwsearch_feed USING (true);",
    )
    .unwrap();
    println!("schema ok");
}

fn insert_feed(
    t: &mut Transaction,
    user: &Uuid,
    op: i16,
    vault: Option<&Uuid>,
    note: Option<&Uuid>,
    point: Option<&Uuid>,
    stamp: i64,
    terms: Option<&[u8]>,
) {
    t.execute(
        "INSERT INTO keyword_feed (user_id, op, vault_id, note_id, point_id, stamp, terms) VALUES ($1,$2,$3,$4,$5,$6,$7)",
        &[user, &op, &vault, &note, &point, &stamp, &terms],
    )
    .unwrap();
}

/// The note's full point set after this pass (op DELETE_NOTE_EXCEPT),
/// written FIRST in every note-scoped transaction.
fn insert_except(t: &mut Transaction, user: &Uuid, vault: &Uuid, note: &Uuid, stamp: i64, keep: &[Uuid]) {
    t.execute(
        "INSERT INTO keyword_feed (user_id, op, vault_id, note_id, stamp, keep) VALUES ($1,$2,$3,$4,$5,$6)",
        &[user, &kwfeed::DELETE_NOTE_EXCEPT, vault, note, &stamp, &keep],
    )
    .unwrap();
}

/// Content-derived point id (prod: UUIDv5 over note, fingerprint, ordinal).
fn point_id(note: &Uuid, terms: &[u8]) -> Uuid {
    Uuid::from_u64_pair(fnv(&[note.as_bytes().as_slice(), terms].concat()), fnv(terms))
}

/// A chunk's terms: 20-120 distinct ids from the user's own (HMAC-like)
/// dim space, Zipf-ish ranks, counts 1-3.
fn terms(rng: &mut StdRng, user: &Uuid) -> Vec<u8> {
    let n = rng.random_range(20..120);
    kwfeed::pack((0..n).map(|_| {
        let rank = (rng.random::<f64>().powi(3) * 50_000.0) as u64;
        let dim = fnv(&[user.as_bytes().as_slice(), &rank.to_le_bytes()].concat()) as u32;
        (dim, rng.random_range(1..4))
    }))
}

fn tenant(i: usize, seed: u64) -> (Uuid, [Uuid; 2]) {
    let u = Uuid::from_u64_pair(seed, i as u64);
    (u, [Uuid::from_u64_pair(seed ^ 1, i as u64), Uuid::from_u64_pair(seed ^ 2, i as u64)])
}

/// Random edit/delete workload over KW_TENANTS tenants on KW_THREADS
/// connections for KW_SECS seconds, writing truth rows and feed rows in ONE
/// transaction each (the transactional outbox). Users and vaults that get
/// deleted are dead for good, like UUIDs in prod.
fn gen() {
    let tenants = env_n("KW_TENANTS", 200);
    let threads = env_n("KW_THREADS", 8);
    let secs = env_n("KW_SECS", 60) as u64;
    let seed = env_n("KW_SEED", 1) as u64;
    let mut c = db();
    for i in 0..tenants {
        let (u, vs) = tenant(i, seed);
        c.execute("INSERT INTO truth_users VALUES ($1) ON CONFLICT DO NOTHING", &[&u]).unwrap();
        for v in vs {
            c.execute("INSERT INTO truth_vaults VALUES ($1,$2) ON CONFLICT DO NOTHING", &[&v, &u]).unwrap();
        }
    }
    let end = Instant::now() + Duration::from_secs(secs);
    let hs: Vec<_> = (0..threads)
        .map(|th| {
            std::thread::spawn(move || {
                let mut rng = StdRng::seed_from_u64(seed * 1000 + th as u64);
                let mut c = db();
                let mut n = [0u64; 5];
                while Instant::now() < end {
                    let (u, vs) = tenant(rng.random_range(0..tenants), seed);
                    let v = vs[rng.random_range(0..2)];
                    let note = Uuid::from_u64_pair(fnv(v.as_bytes()), rng.random_range(0..40));
                    let roll = rng.random_range(0..1000);
                    let kind = match roll {
                        0..820 => 0,
                        820..960 => 1,
                        960..997 => 2,
                        997..999 => 3,
                        _ => 4,
                    };
                    if one_op(&mut c, &mut rng, kind, &u, &v, &note) {
                        n[kind] += 1;
                    }
                }
                n
            })
        })
        .collect();
    let mut tot = [0u64; 5];
    for h in hs {
        for (t, x) in tot.iter_mut().zip(h.join().unwrap()) {
            *t += x;
        }
    }
    println!("{}", json!({"edits": tot[0], "note_deletes": tot[1], "point_deletes": tot[2], "vault_deletes": tot[3], "user_deletes": tot[4]}));
}

/// One transaction. Returns false if the user or vault is already dead.
fn one_op(c: &mut Client, rng: &mut StdRng, kind: usize, u: &Uuid, v: &Uuid, note: &Uuid) -> bool {
    let mut t = c.transaction().unwrap();
    let lock = if kind >= 3 { "FOR UPDATE" } else { "FOR SHARE" };
    let udead: bool = t.query_one(&format!("SELECT dead FROM truth_users WHERE user_id=$1 {lock}"), &[u]).unwrap().get(0);
    let vdead: bool = t.query_one(&format!("SELECT dead FROM truth_vaults WHERE vault_id=$1 {lock}"), &[v]).unwrap().get(0);
    if udead || vdead {
        return false;
    }
    match kind {
        3 => {
            t.execute("UPDATE truth_vaults SET dead=true WHERE vault_id=$1", &[v]).unwrap();
            t.execute("DELETE FROM truth_chunks WHERE vault_id=$1", &[v]).unwrap();
            insert_feed(&mut t, u, kwfeed::DELETE_VAULT, Some(v), None, None, 0, None);
        }
        4 => {
            t.execute("UPDATE truth_users SET dead=true WHERE user_id=$1", &[u]).unwrap();
            t.execute("DELETE FROM truth_chunks WHERE user_id=$1", &[u]).unwrap();
            insert_feed(&mut t, u, kwfeed::DELETE_USER, None, None, None, 0, None);
        }
        _ => {
            // Per-note monotonic stamp under the note's row lock.
            let stamp: i64 = t
                .query_one(
                    "INSERT INTO truth_notes VALUES ($1,$2,$3,1) ON CONFLICT (note_id)
                     DO UPDATE SET stamp = truth_notes.stamp + 1 RETURNING stamp",
                    &[note, u, v],
                )
                .unwrap()
                .get(0);
            let have: Vec<Uuid> = t
                .query("SELECT point_id FROM truth_chunks WHERE note_id=$1", &[note])
                .unwrap()
                .iter()
                .map(|r| r.get(0))
                .collect();
            match kind {
                1 => {
                    t.execute("DELETE FROM truth_chunks WHERE note_id=$1", &[note]).unwrap();
                    insert_feed(&mut t, u, kwfeed::DELETE_NOTE, Some(v), Some(note), None, stamp, None);
                }
                2 => {
                    let (gone, keep): (Vec<Uuid>, Vec<Uuid>) = have.iter().partition(|_| rng.random_bool(0.5));
                    insert_except(&mut t, u, v, note, stamp, &keep);
                    for p in &gone {
                        t.execute("DELETE FROM truth_chunks WHERE point_id=$1", &[p]).unwrap();
                        insert_feed(&mut t, u, kwfeed::DELETE_POINTS, Some(v), Some(note), Some(p), stamp, None);
                    }
                }
                _ => {
                    // Edit: keep some chunks (no row of their own, like an
                    // unchanged chunk keeping its point id), drop some, add 1-4.
                    let (gone, mut keep): (Vec<Uuid>, Vec<Uuid>) = have.iter().partition(|_| rng.random_bool(0.4));
                    let new: Vec<(Uuid, Vec<u8>)> = (0..rng.random_range(1..5))
                        .map(|_| {
                            let ts = terms(rng, u);
                            (point_id(note, &ts), ts)
                        })
                        .collect();
                    keep.extend(new.iter().map(|n| n.0));
                    insert_except(&mut t, u, v, note, stamp, &keep);
                    for p in &gone {
                        t.execute("DELETE FROM truth_chunks WHERE point_id=$1", &[p]).unwrap();
                    }
                    for (p, ts) in &new {
                        t.execute(
                            "INSERT INTO truth_chunks VALUES ($1,$2,$3,$4,$5) ON CONFLICT (point_id) DO NOTHING",
                            &[p, u, v, note, ts],
                        )
                        .unwrap();
                        insert_feed(&mut t, u, kwfeed::UPSERT, Some(v), Some(note), Some(p), stamp, Some(ts));
                    }
                }
            }
        }
    }
    t.commit().unwrap();
    true
}

/// Write burst: KW_TENANTS tenants x KW_CHUNKS chunk upserts, one
/// transaction per tenant, on KW_THREADS connections. Feed rows only.
fn burst() {
    let tenants = env_n("KW_TENANTS", 20_000);
    let chunks = env_n("KW_CHUNKS", 20);
    let threads = env_n("KW_THREADS", 8);
    let seed = env_n("KW_SEED", 7) as u64;
    let t0 = Instant::now();
    let hs: Vec<_> = (0..threads)
        .map(|th| {
            std::thread::spawn(move || {
                let mut rng = StdRng::seed_from_u64(seed + th as u64);
                let mut c = db();
                for i in (th..tenants).step_by(threads) {
                    let (u, vs) = tenant(i, seed << 8);
                    let mut t = c.transaction().unwrap();
                    for k in 0..chunks {
                        let note = Uuid::from_u64_pair(fnv(u.as_bytes()), (k / 4) as u64);
                        let ts = terms(&mut rng, &u);
                        insert_feed(&mut t, &u, kwfeed::UPSERT, Some(&vs[0]), Some(&note), Some(&Uuid::from_u128(rand::random())), 1, Some(&ts));
                    }
                    t.commit().unwrap();
                }
            })
        })
        .collect();
    hs.into_iter().for_each(|h| h.join().unwrap());
    println!("{}", json!({"tenants": tenants, "rows": tenants * chunks, "secs": t0.elapsed().as_secs_f64()}));
}

/// The keyword bench's corpus (`corpus.jsonl`: crc32 dims + tf per chunk)
/// as the eval tenant, KW_REPS copies (posting lists x reps, the bench's
/// worst case), plus KW_FILLERS filler tenants placed in the SAME shard,
/// each a KW_FILLER_CHUNKS sample of the corpus re-keyed per tenant (term
/// ids remapped by a per-tenant hash, as a different HMAC key would).
fn load_eval() {
    let corpus = env("KW_CORPUS", "/secrets/corpus.jsonl");
    let reps = env_n("KW_REPS", 1);
    let fillers = env_n("KW_FILLERS", 0);
    let filler_chunks = env_n("KW_FILLER_CHUNKS", 800);
    let user: Uuid = env("KW_EVAL_USER", "00000000-0000-4000-8000-00000000e7a1").parse().unwrap();
    let vault = Uuid::from_u64_pair(fnv(user.as_bytes()), 0);
    let rows: Vec<(u64, u64, Vec<u8>)> = std::fs::read_to_string(&corpus)
        .unwrap()
        .lines()
        .map(|l| {
            let v: Value = serde_json::from_str(l).unwrap();
            let terms = v["terms"].as_array().unwrap().iter().map(|x| x.as_u64().unwrap() as u32);
            let tf = v["tf"].as_array().unwrap().iter().map(|x| x.as_u64().unwrap() as u32);
            (v["id"].as_u64().unwrap(), v["note"].as_u64().unwrap(), kwfeed::pack(terms.zip(tf)))
        })
        .collect();
    let mut c = db();
    let t0 = Instant::now();
    let write = |c: &mut Client, u: &Uuid, v: &Uuid, docs: &mut dyn Iterator<Item = (Uuid, Uuid, Vec<u8>)>| {
        let mut t = c.transaction().unwrap();
        let mut n = 0;
        for (note, point, terms) in docs {
            insert_feed(&mut t, u, kwfeed::UPSERT, Some(v), Some(&note), Some(&point), 1, Some(&terms));
            n += 1;
            if n % 5000 == 0 {
                t.commit().unwrap();
                t = c.transaction().unwrap();
            }
        }
        t.commit().unwrap();
    };
    for rep in 0..reps as u64 {
        // Point id encodes (rep, chunk id), note id (rep, note): bench ids map back.
        let mut it = rows
            .iter()
            .map(|(id, note, terms)| (Uuid::from_u64_pair(0xe7a1, (rep << 32) | note), Uuid::from_u64_pair(rep, *id), terms.clone()));
        write(&mut c, &user, &vault, &mut it);
    }
    let target = shard_of(&user);
    let mut rng = StdRng::seed_from_u64(11);
    let mut placed = 0;
    let mut i = 0u64;
    while placed < fillers {
        i += 1;
        let u = Uuid::from_u64_pair(0xf111, i);
        if shard_of(&u) != target {
            continue;
        }
        placed += 1;
        let v = Uuid::from_u64_pair(fnv(u.as_bytes()), 0);
        let mut it = (0..filler_chunks).map(|_| {
            let (_, note, terms) = &rows[rng.random_range(0..rows.len())];
            let remapped = kwfeed::unpack(terms)
                .unwrap()
                .into_iter()
                .map(|(t, n)| (fnv(&[u.as_bytes().as_slice(), &t.to_le_bytes()].concat()) as u32, n));
            (Uuid::from_u64_pair(i, *note), Uuid::from_u128(rand::random()), kwfeed::pack(remapped))
        });
        write(&mut c, &u, &v, &mut it);
    }
    println!("{}", json!({"eval_user": user, "vault": vault, "shard": target, "chunks": rows.len() * reps,
                          "fillers": fillers, "secs": t0.elapsed().as_secs_f64()}));
}

/// Index (all shards, read from disk) vs truth_chunks: same live point set,
/// same terms per point (fnv of the packed column), no point twice.
fn verify() {
    let dir = PathBuf::from(env("KW_DATA", "/data/kw"));
    let mut seen: HashMap<Uuid, u64> = HashMap::new();
    let mut dups = 0;
    for i in 0..SHARDS {
        let s = Shard::open(&dir.join(format!("s{i:03}"))).unwrap();
        for (p, _len, crc) in s.dump() {
            if seen.insert(p, crc).is_some() {
                dups += 1;
            }
        }
    }
    let mut c = db();
    let truth: HashMap<Uuid, u64> = c
        .query("SELECT point_id, terms FROM truth_chunks", &[])
        .unwrap()
        .iter()
        .map(|r| (r.get(0), fnv(r.get::<_, &[u8]>(1))))
        .collect();
    let missing_ids: Vec<&Uuid> = truth.keys().filter(|p| !seen.contains_key(p)).collect();
    let missing = missing_ids.len();
    eprintln!("missing sample: {:?}", &missing_ids[..missing.min(5)]);
    let extra = seen.keys().filter(|p| !truth.contains_key(p)).count();
    let stale = truth.iter().filter(|(p, crc)| seen.get(p).is_some_and(|c| c != *crc)).count();
    let r = json!({"truth": truth.len(), "index": seen.len(), "missing": missing, "extra": extra,
                   "stale_content": stale, "duplicates": dups});
    println!("{r}");
    if missing + extra + stale + dups > 0 {
        std::process::exit(1);
    }
}

/// Bytes on disk per shard directory and doc counts, for the size figure.
fn du() {
    let dir = PathBuf::from(env("KW_DATA", "/data/kw"));
    let shard = env_n("KW_SHARD", 0);
    let p = dir.join(format!("s{shard:03}"));
    let mut by: HashMap<String, u64> = HashMap::new();
    for e in std::fs::read_dir(&p).unwrap() {
        let e = e.unwrap();
        let name = e.file_name().into_string().unwrap();
        let ext = name.rsplit('.').next().unwrap_or("").to_string();
        *by.entry(ext).or_default() += e.metadata().unwrap().len();
    }
    let s = Shard::open(&p).unwrap();
    let searcher = s.reader.searcher();
    let docs: u64 = searcher.segment_readers().iter().map(|r| r.num_docs() as u64).sum();
    println!("{}", json!({"shard": shard, "bytes": by, "total": by.values().sum::<u64>(), "alive_docs": docs,
                          "segments": searcher.segment_readers().len()}));
}

fn post(agent: &ureq::Agent, url: &str, secret: &str, body: &str) -> Value {
    agent
        .post(&format!("{url}/search"))
        .set("authorization", &format!("Bearer {secret}"))
        .set("content-type", "application/json")
        .send_string(body)
        .map(|r| serde_json::from_reader::<_, Value>(r.into_reader()).unwrap())
        .unwrap_or_else(|e| panic!("search failed: {e}"))
}

fn pct(xs: &mut [f64]) -> Value {
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let at = |q: f64| xs[((xs.len() as f64 * q) as usize).min(xs.len() - 1)];
    json!({"n": xs.len(), "p50": (at(0.5) * 100.0).round() / 100.0, "p95": (at(0.95) * 100.0).round() / 100.0,
           "max": (xs[xs.len() - 1] * 100.0).round() / 100.0})
}

/// `bench <queries.json> <mode> <out.json>`. Modes:
/// quality / quality_shard: every query once, top 40, run file in the
/// keyword bench's format (`runs` = qid -> chunk ids). warm: KW_PASSES
/// passes, client-side ms (keep-alive). cold: KW_N queries once (run right
/// after a restart with the page cache evicted). Filters: KW_INCLUDE /
/// KW_EXCLUDE = number of note ids (json strings, or base64 when KW_B64=1).
fn bench(args: &[String]) {
    let qs: Value = serde_json::from_str(&std::fs::read_to_string(&args[0]).unwrap()).unwrap();
    let mode = args[1].as_str();
    let url = env("KW_URL", "http://127.0.0.1:7700");
    let secret = std::fs::read_to_string(env("KW_SECRET_FILE", "/secrets/kwsecret")).unwrap().trim().to_string();
    let user: Uuid = env("KW_EVAL_USER", "00000000-0000-4000-8000-00000000e7a1").parse().unwrap();
    let vault = Uuid::from_u64_pair(fnv(user.as_bytes()), 0);
    let reps = env_n("KW_REPS", 1) as u64;
    let notes = env_n("KW_NOTES", 2219) as u64;
    let mut rng = StdRng::seed_from_u64(3);
    let mut pick = |n: usize| -> Vec<Uuid> {
        let mut s = HashSet::new();
        while s.len() < n {
            s.insert(Uuid::from_u64_pair(0xe7a1, (rng.random_range(0..reps) << 32) | rng.random_range(0..notes)));
        }
        s.into_iter().collect()
    };
    let (inc, exc) = (pick(env_n("KW_INCLUDE", 0)), pick(env_n("KW_EXCLUDE", 0)));
    let b64 = env("KW_B64", "0") == "1";
    let enc = |ids: &[Uuid]| base64::engine::general_purpose::STANDARD.encode(ids.iter().flat_map(|u| *u.as_bytes()).collect::<Vec<u8>>());
    let mut base = json!({"user": user, "vaults": [vault], "limit": env_n("KW_LIMIT", 40)});
    if !inc.is_empty() {
        if b64 { base["include_b64"] = json!(enc(&inc)) } else { base["include"] = json!(inc) }
    }
    if !exc.is_empty() {
        if b64 { base["exclude_b64"] = json!(enc(&exc)) } else { base["exclude"] = json!(exc) }
    }
    let agent = ureq::AgentBuilder::new().build();
    let mut all: Vec<(String, String, Vec<u32>)> = qs["queries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|q| (q["qid"].as_str().unwrap().into(), q["set"].as_str().unwrap().into(),
                  q["terms"].as_array().unwrap().iter().map(|t| t.as_u64().unwrap() as u32).collect()))
        .collect();
    for (i, c) in qs["common"].as_array().unwrap().iter().enumerate() {
        all.push((format!("c{i:02}"), "common".into(), c.as_array().unwrap().iter().map(|t| t.as_u64().unwrap() as u32).collect()));
    }
    let body = |terms: &[u32], shard_stats: bool| {
        let mut b = base.clone();
        b["terms"] = json!(terms);
        b["shard_stats"] = json!(shard_stats);
        b.to_string()
    };
    let out = match mode {
        "quality" | "quality_shard" => {
            let runs: serde_json::Map<String, Value> = all
                .iter()
                .filter(|q| q.1 != "common")
                .map(|(qid, _, terms)| {
                    let r = post(&agent, &url, &secret, &body(terms, mode == "quality_shard"));
                    let ids: Vec<u64> = r["hits"].as_array().unwrap().iter()
                        .map(|h| h[0].as_str().unwrap().parse::<Uuid>().unwrap().as_u64_pair().1).collect();
                    (qid.clone(), json!(ids))
                })
                .collect();
            json!({"unit": "chunk", "runs": runs})
        }
        "warm" | "cold" => {
            let passes = if mode == "warm" { env_n("KW_PASSES", 3) } else { 1 };
            let n = if mode == "cold" { env_n("KW_N", 60) } else { all.len() };
            let mut by: HashMap<String, Vec<f64>> = HashMap::new();
            let mut server: Vec<f64> = Vec::new();
            for _ in 0..passes {
                for (_, set, terms) in all.iter().skip(env_n("KW_SKIP", 0)).take(n) {
                    let b = body(terms, env("KW_SHARD_STATS", "0") == "1");
                    let t = Instant::now();
                    let r = post(&agent, &url, &secret, &b);
                    let ms = t.elapsed().as_secs_f64() * 1e3;
                    let kind = set.split(':').next().unwrap().to_string();
                    by.entry(kind).or_default().push(ms);
                    by.entry("all".into()).or_default().push(ms);
                    server.push(r["took_us"].as_f64().unwrap() / 1e3);
                }
            }
            let mut m: serde_json::Map<String, Value> = by.iter_mut().map(|(k, v)| (k.clone(), pct(v))).collect();
            m.insert("server_all".into(), pct(&mut server));
            m.insert("request_bytes_typical".into(), json!(body(&all[0].2, false).len()));
            json!({"mode": mode, "include": inc.len(), "exclude": exc.len(), "b64": b64, "lat_ms": m})
        }
        _ => panic!("mode"),
    };
    std::fs::write(&args[2], serde_json::to_string_pretty(&out).unwrap()).unwrap();
    if !mode.starts_with("quality") {
        println!("{}", out);
    }
}

fn search_ids(agent: &ureq::Agent, url: &str, secret: &str, user: &Uuid, vault: &Uuid, terms: &[u32]) -> Vec<Uuid> {
    let r = post(agent, url, secret, &json!({"user": user, "vaults": [vault], "terms": terms, "limit": 100}).to_string());
    r["hits"].as_array().unwrap().iter().map(|h| h[0].as_str().unwrap().parse().unwrap()).collect()
}

fn wait_rounds() {
    std::thread::sleep(Duration::from_millis(env_n("KW_WAIT_MS", 2500) as u64));
}

/// (1) A lower xid committing after a higher one is still applied, and the
/// reader holds its cursor below the open transaction meanwhile. (2) A late
/// upsert (higher xid, committed BEFORE a delete_user / delete_vault with a
/// lower xid) never resurrects docs: the tombstone drops it.
fn xidtest() {
    let url = env("KW_URL", "http://127.0.0.1:7700");
    let secret = std::fs::read_to_string(env("KW_SECRET_FILE", "/secrets/kwsecret")).unwrap().trim().to_string();
    let agent = ureq::AgentBuilder::new().build();
    let run = Uuid::from_u128(rand::random()).as_u64_pair().0;
    let terms = |u: &Uuid| kwfeed::pack([(fnv(u.as_bytes()) as u32, 2)]);
    let term = |u: &Uuid| vec![fnv(u.as_bytes()) as u32];
    let mut report = serde_json::Map::new();

    // Phase 3 (run after a restart): a new upsert for a user deleted before
    // the restart is still dropped, so tombstones survived in the commit.
    if let Ok(u) = std::env::var("KW_LATE_USER") {
        let u: Uuid = u.parse().unwrap();
        let (hi, lo) = u.as_u64_pair();
        let (v, n, p) = (Uuid::from_u64_pair(hi, lo + 1), Uuid::from_u64_pair(hi, lo + 2), Uuid::from_u64_pair(hi, lo + 9));
        let mut c = db();
        let mut t = c.transaction().unwrap();
        insert_feed(&mut t, &u, kwfeed::UPSERT, Some(&v), Some(&n), Some(&p), 9, Some(&terms(&u)));
        t.commit().unwrap();
        wait_rounds();
        let after = search_ids(&agent, &url, &secret, &u, &v, &term(&u));
        println!("{}", json!({"upsert_after_restart_for_deleted_user": u, "visible": after.len(), "pass": after.is_empty()}));
        std::process::exit(if after.is_empty() { 0 } else { 1 });
    }

    // (1) seq 101 commits after 102.
    let (u, v, n) = (Uuid::from_u64_pair(run, 1), Uuid::from_u64_pair(run, 2), Uuid::from_u64_pair(run, 3));
    let (pa, pb) = (Uuid::from_u64_pair(run, 10), Uuid::from_u64_pair(run, 11));
    let (mut ca, mut cb, mut probe) = (db(), db(), db());
    let mut ta = ca.transaction().unwrap();
    insert_feed(&mut ta, &u, kwfeed::UPSERT, Some(&v), Some(&n), Some(&pa), 1, Some(&terms(&u)));
    let (seq_a, xid_a): (i64, String) = {
        let r = ta.query_one("SELECT max(seq), pg_current_xact_id()::text FROM keyword_feed WHERE point_id=$1", &[&pa]).unwrap();
        (r.get(0), r.get(1))
    };
    let mut tb = cb.transaction().unwrap();
    insert_feed(&mut tb, &u, kwfeed::UPSERT, Some(&v), Some(&n), Some(&pb), 1, Some(&terms(&u)));
    let r = tb.query_one("SELECT max(seq), pg_current_xact_id()::text FROM keyword_feed WHERE point_id=$1", &[&pb]).unwrap();
    let (seq_b, xid_b): (i64, String) = (r.get(0), r.get(1));
    tb.commit().unwrap();
    wait_rounds();
    let mid = search_ids(&agent, &url, &secret, &u, &v, &term(&u));
    // What a naive `seq > cursor` reader sees right now: B committed, A not.
    let naive_max: i64 = probe.query_one("SELECT max(seq) FROM keyword_feed", &[]).unwrap().get(0);
    ta.commit().unwrap();
    wait_rounds();
    let after = search_ids(&agent, &url, &secret, &u, &v, &term(&u));
    let ok1 = !mid.contains(&pb) && !mid.contains(&pa) && after.contains(&pa) && after.contains(&pb);
    report.insert("lower_xid_commits_later".into(), json!({
        "a": {"seq": seq_a, "xid": xid_a}, "b": {"seq": seq_b, "xid": xid_b},
        "naive_seq_reader_would_be_at": naive_max, "naive_skips_a": naive_max >= seq_b && seq_a < seq_b,
        "visible_while_a_open": mid.len(), "visible_after_a_commits": after.len(), "pass": ok1}));

    // (2) tombstones, for a user and for a vault.
    let mut ok2 = true;
    for (label, op) in [("delete_user", kwfeed::DELETE_USER), ("delete_vault", kwfeed::DELETE_VAULT)] {
        let k = if op == kwfeed::DELETE_USER { 100 } else { 200 };
        let (u, v, n) = (Uuid::from_u64_pair(run, k), Uuid::from_u64_pair(run, k + 1), Uuid::from_u64_pair(run, k + 2));
        let (p0, late) = (Uuid::from_u64_pair(run, k + 3), Uuid::from_u64_pair(run, k + 4));
        let mut c0 = db();
        let mut t0 = c0.transaction().unwrap();
        insert_feed(&mut t0, &u, kwfeed::UPSERT, Some(&v), Some(&n), Some(&p0), 1, Some(&terms(&u)));
        t0.commit().unwrap();
        wait_rounds();
        let before = search_ids(&agent, &url, &secret, &u, &v, &term(&u));
        // C takes the LOWER xid first, D upserts with a higher xid and commits, then C deletes.
        let (mut cc, mut cd) = (db(), db());
        let mut tc = cc.transaction().unwrap();
        let xid_c: String = tc.query_one("SELECT pg_current_xact_id()::text", &[]).unwrap().get(0);
        let mut td = cd.transaction().unwrap();
        insert_feed(&mut td, &u, kwfeed::UPSERT, Some(&v), Some(&n), Some(&late), 2, Some(&terms(&u)));
        let xid_d: String = td.query_one("SELECT pg_current_xact_id()::text", &[]).unwrap().get(0);
        td.commit().unwrap();
        insert_feed(&mut tc, &u, op, Some(&v).filter(|_| op == kwfeed::DELETE_VAULT), None, None, 0, None);
        tc.commit().unwrap();
        wait_rounds();
        let after = search_ids(&agent, &url, &secret, &u, &v, &term(&u));
        let ok = before == vec![p0] && after.is_empty() && xid_c.parse::<u64>().unwrap() < xid_d.parse::<u64>().unwrap();
        ok2 &= ok;
        report.insert(label.into(), json!({"xid_delete": xid_c, "xid_late_upsert": xid_d, "before": before.len(),
                                           "after": after.len(), "pass": ok, "user": u}));
    }
    report.insert("pass".into(), json!(ok1 && ok2));
    println!("{}", Value::Object(report));
    if !(ok1 && ok2) {
        std::process::exit(1);
    }
}
