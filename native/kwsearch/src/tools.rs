//! Integration harness (subcommands of the binary): schema, workload
//! generators, verify, bench, the xid test, the restore test. Run against a
//! THROWAWAY Postgres only (`native/kwsearch/it/`).

use crate::shard::{fnv, shard_of, Shard, SHARDS};
use crate::{env, env_n};
use base64::Engine;
use postgres::{Client, NoTls, Transaction};
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
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
        "token" => println!("{}", token(&args.join(" "))),
        "stats" => {
            let u: Uuid = args[0].parse().unwrap();
            let (n, t) = Shard::open(&shard_dir(shard_of(&u)))
                .unwrap()
                .user_stats(&u);
            println!("{n} {t}");
        }
        _ => panic!("unknown command {cmd}"),
    }
}

fn db() -> Client {
    Client::connect(&env("KW_SUPER_URL", ""), NoTls).expect("connect KW_SUPER_URL")
}

/// Signs a token with the first key of KW_TOKEN_KEYS_FILE. `args` is the
/// payload JSON without `exp` ("ops" alone means `{"s":"ops"}`).
fn token(payload: &str) -> String {
    let keys = std::fs::read_to_string(env("KW_TOKEN_KEYS_FILE", "/secrets/tokenkeys")).unwrap();
    let key = keys.lines().next().unwrap().trim();
    let mut p: Value = if payload.trim() == "ops" {
        json!({"s": "ops"})
    } else {
        serde_json::from_str(payload).unwrap()
    };
    p["exp"] = json!(crate::feed::now() + 120);
    crate::token::sign(key.as_bytes(), &p.to_string())
}

/// The feed tables as the Elixir migration creates them, the reader role,
/// and the generator's truth tables (what the index must equal at the end).
/// The role password here is plaintext on purpose: harness only, throwaway
/// database (the app creates the real role through the SCRAM path, F13).
fn schema() {
    let feed_pw = std::fs::read_to_string(env("KW_FEED_PW_FILE", "/secrets/feedpw")).unwrap();
    let mut c = db();
    c.batch_execute(
        "CREATE TABLE IF NOT EXISTS keyword_feed (
           seq bigserial PRIMARY KEY,
           xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
           inserted_at timestamptz NOT NULL DEFAULT now(),
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
         CREATE TABLE IF NOT EXISTS keyword_deletions (
           seq bigserial PRIMARY KEY,
           xid xid8 NOT NULL DEFAULT pg_current_xact_id(),
           inserted_at timestamptz NOT NULL DEFAULT now(),
           user_id uuid NOT NULL, op smallint NOT NULL, vault_id uuid, note_id uuid);
         ALTER TABLE keyword_deletions ENABLE ROW LEVEL SECURITY;
         ALTER TABLE keyword_deletions FORCE ROW LEVEL SECURITY;
         CREATE TABLE IF NOT EXISTS keyword_feed_horizon (
           id smallint PRIMARY KEY CHECK (id = 1), xid xid8 NOT NULL, seq bigint NOT NULL,
           updated_at timestamptz NOT NULL DEFAULT now());
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
    let exists = c
        .query_opt(
            "SELECT 1 FROM pg_roles WHERE rolname = 'kwsearch_feed'",
            &[],
        )
        .unwrap()
        .is_some();
    if !exists {
        c.batch_execute("CREATE ROLE kwsearch_feed NOINHERIT LOGIN CONNECTION LIMIT 4")
            .unwrap();
    }
    c.batch_execute(&format!(
        "ALTER ROLE kwsearch_feed PASSWORD '{}'",
        feed_pw.trim().replace('\'', "''")
    ))
    .unwrap();
    c.batch_execute(
        "ALTER ROLE kwsearch_feed SET statement_timeout = '30s';
         GRANT USAGE ON SCHEMA public TO kwsearch_feed;
         GRANT SELECT ON keyword_feed, keyword_deletions, keyword_feed_horizon TO kwsearch_feed;
         DROP POLICY IF EXISTS kwsearch_feed_read ON keyword_feed;
         CREATE POLICY kwsearch_feed_read ON keyword_feed FOR SELECT TO kwsearch_feed USING (true);
         DROP POLICY IF EXISTS kwsearch_feed_read ON keyword_deletions;
         CREATE POLICY kwsearch_feed_read ON keyword_deletions FOR SELECT TO kwsearch_feed USING (true);",
    )
    .unwrap();
    println!("schema ok");
}

#[allow(clippy::too_many_arguments)]
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

/// The durable deletion log row, in the same transaction as the feed row.
fn insert_deletion(
    t: &mut Transaction,
    user: &Uuid,
    op: i16,
    vault: Option<&Uuid>,
    note: Option<&Uuid>,
) {
    t.execute(
        "INSERT INTO keyword_deletions (user_id, op, vault_id, note_id) VALUES ($1,$2,$3,$4)",
        &[user, &op, &vault, &note],
    )
    .unwrap();
}

/// The note's full point set after this pass (op DELETE_NOTE_EXCEPT),
/// written FIRST in every note-scoped transaction.
fn insert_except(
    t: &mut Transaction,
    user: &Uuid,
    vault: &Uuid,
    note: &Uuid,
    stamp: i64,
    keep: &[Uuid],
) {
    t.execute(
        "INSERT INTO keyword_feed (user_id, op, vault_id, note_id, stamp, keep) VALUES ($1,$2,$3,$4,$5,$6)",
        &[user, &kwfeed::DELETE_NOTE_EXCEPT, vault, note, &stamp, &keep],
    )
    .unwrap();
}

/// Content-derived point id (prod: UUIDv5 over note, fingerprint, ordinal).
fn point_id(note: &Uuid, terms: &[u8]) -> Uuid {
    Uuid::from_u64_pair(
        fnv(&[note.as_bytes().as_slice(), terms].concat()),
        fnv(terms),
    )
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
    (
        u,
        [
            Uuid::from_u64_pair(seed ^ 1, i as u64),
            Uuid::from_u64_pair(seed ^ 2, i as u64),
        ],
    )
}

/// Random edit/delete workload over KW_TENANTS tenants on KW_THREADS
/// connections for KW_SECS seconds, writing truth rows, feed rows and
/// deletion-log rows in ONE transaction each (the transactional outbox).
fn gen() {
    let tenants = env_n("KW_TENANTS", 200);
    let threads = env_n("KW_THREADS", 8);
    let secs = env_n("KW_SECS", 60) as u64;
    let seed = env_n("KW_SEED", 1) as u64;
    // KW_OPS: stop after this many ops per thread (deterministic with one thread).
    let max_ops = env_n("KW_OPS", 0) as u64;
    let mut c = db();
    for i in 0..tenants {
        let (u, vs) = tenant(i, seed);
        c.execute(
            "INSERT INTO truth_users VALUES ($1) ON CONFLICT DO NOTHING",
            &[&u],
        )
        .unwrap();
        for v in vs {
            c.execute(
                "INSERT INTO truth_vaults VALUES ($1,$2) ON CONFLICT DO NOTHING",
                &[&v, &u],
            )
            .unwrap();
        }
    }
    let end = Instant::now() + Duration::from_secs(secs);
    let hs: Vec<_> = (0..threads)
        .map(|th| {
            std::thread::spawn(move || {
                let mut rng = StdRng::seed_from_u64(seed * 1000 + th as u64);
                let mut c = db();
                let mut n = [0u64; 5];
                let mut done = 0u64;
                while Instant::now() < end && (max_ops == 0 || done < max_ops) {
                    done += 1;
                    let (u, vs) = tenant(rng.random_range(0..tenants), seed);
                    let v = vs[rng.random_range(0..2)];
                    let note = Uuid::from_u64_pair(fnv(v.as_bytes()), rng.random_range(0..40));
                    let kind = match rng.random_range(0..1000) {
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
    println!(
        "{}",
        json!({"edits": tot[0], "note_deletes": tot[1], "point_deletes": tot[2], "vault_deletes": tot[3], "user_deletes": tot[4]})
    );
}

/// One transaction. Returns false if the user or vault is already dead.
fn one_op(c: &mut Client, rng: &mut StdRng, kind: usize, u: &Uuid, v: &Uuid, note: &Uuid) -> bool {
    let mut t = c.transaction().unwrap();
    let lock = if kind >= 3 { "FOR UPDATE" } else { "FOR SHARE" };
    let udead: bool = t
        .query_one(
            &format!("SELECT dead FROM truth_users WHERE user_id=$1 {lock}"),
            &[u],
        )
        .unwrap()
        .get(0);
    let vdead: bool = t
        .query_one(
            &format!("SELECT dead FROM truth_vaults WHERE vault_id=$1 {lock}"),
            &[v],
        )
        .unwrap()
        .get(0);
    if udead || vdead {
        return false;
    }
    match kind {
        3 => {
            t.execute("UPDATE truth_vaults SET dead=true WHERE vault_id=$1", &[v])
                .unwrap();
            t.execute("DELETE FROM truth_chunks WHERE vault_id=$1", &[v])
                .unwrap();
            insert_feed(
                &mut t,
                u,
                kwfeed::DELETE_VAULT,
                Some(v),
                None,
                None,
                0,
                None,
            );
            insert_deletion(&mut t, u, kwfeed::DELETE_VAULT, Some(v), None);
        }
        4 => {
            t.execute("UPDATE truth_users SET dead=true WHERE user_id=$1", &[u])
                .unwrap();
            t.execute("DELETE FROM truth_chunks WHERE user_id=$1", &[u])
                .unwrap();
            insert_feed(&mut t, u, kwfeed::DELETE_USER, None, None, None, 0, None);
            insert_deletion(&mut t, u, kwfeed::DELETE_USER, None, None);
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
                .query(
                    "SELECT point_id FROM truth_chunks WHERE note_id=$1",
                    &[note],
                )
                .unwrap()
                .iter()
                .map(|r| r.get(0))
                .collect();
            match kind {
                1 => {
                    t.execute("DELETE FROM truth_chunks WHERE note_id=$1", &[note])
                        .unwrap();
                    insert_feed(
                        &mut t,
                        u,
                        kwfeed::DELETE_NOTE,
                        Some(v),
                        Some(note),
                        None,
                        stamp,
                        None,
                    );
                    insert_deletion(&mut t, u, kwfeed::DELETE_NOTE, Some(v), Some(note));
                }
                2 => {
                    let (gone, keep): (Vec<Uuid>, Vec<Uuid>) =
                        have.iter().partition(|_| rng.random_bool(0.5));
                    insert_except(&mut t, u, v, note, stamp, &keep);
                    for p in &gone {
                        t.execute("DELETE FROM truth_chunks WHERE point_id=$1", &[p])
                            .unwrap();
                        insert_feed(
                            &mut t,
                            u,
                            kwfeed::DELETE_POINTS,
                            Some(v),
                            Some(note),
                            Some(p),
                            stamp,
                            None,
                        );
                    }
                }
                _ => {
                    // Edit: keep some chunks (no row of their own, like an
                    // unchanged chunk keeping its point id), drop some, add 1-4.
                    let (gone, mut keep): (Vec<Uuid>, Vec<Uuid>) =
                        have.iter().partition(|_| rng.random_bool(0.4));
                    let new: Vec<(Uuid, Vec<u8>)> = (0..rng.random_range(1..5))
                        .map(|_| {
                            let ts = terms(rng, u);
                            (point_id(note, &ts), ts)
                        })
                        .collect();
                    keep.extend(new.iter().map(|n| n.0));
                    insert_except(&mut t, u, v, note, stamp, &keep);
                    for p in &gone {
                        t.execute("DELETE FROM truth_chunks WHERE point_id=$1", &[p])
                            .unwrap();
                    }
                    for (p, ts) in &new {
                        t.execute("INSERT INTO truth_chunks VALUES ($1,$2,$3,$4,$5) ON CONFLICT (point_id) DO NOTHING", &[p, u, v, note, ts])
                            .unwrap();
                        insert_feed(
                            &mut t,
                            u,
                            kwfeed::UPSERT,
                            Some(v),
                            Some(note),
                            Some(p),
                            stamp,
                            Some(ts),
                        );
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
                        insert_feed(
                            &mut t,
                            &u,
                            kwfeed::UPSERT,
                            Some(&vs[0]),
                            Some(&note),
                            Some(&Uuid::from_u128(rand::random())),
                            1,
                            Some(&ts),
                        );
                    }
                    t.commit().unwrap();
                }
            })
        })
        .collect();
    hs.into_iter().for_each(|h| h.join().unwrap());
    println!(
        "{}",
        json!({"tenants": tenants, "rows": tenants * chunks, "secs": t0.elapsed().as_secs_f64()})
    );
}

/// The keyword bench's corpus (`corpus.jsonl`: dims + tf per chunk) as the
/// eval tenant, KW_REPS copies, plus KW_FILLERS filler tenants placed in the
/// SAME shard, each a KW_FILLER_CHUNKS sample of the corpus re-keyed per
/// tenant (term ids remapped by a per-tenant hash, as a different HMAC key
/// would).
fn load_eval() {
    let corpus = env("KW_CORPUS", "/secrets/corpus.jsonl");
    let reps = env_n("KW_REPS", 1);
    let fillers = env_n("KW_FILLERS", 0);
    let filler_chunks = env_n("KW_FILLER_CHUNKS", 800);
    let user: Uuid = env("KW_EVAL_USER", "00000000-0000-4000-8000-00000000e7a1")
        .parse()
        .unwrap();
    let vault = Uuid::from_u64_pair(fnv(user.as_bytes()), 0);
    let rows: Vec<(u64, u64, Vec<u8>)> = std::fs::read_to_string(&corpus)
        .unwrap()
        .lines()
        .map(|l| {
            let v: Value = serde_json::from_str(l).unwrap();
            let terms = v["terms"]
                .as_array()
                .unwrap()
                .iter()
                .map(|x| x.as_u64().unwrap() as u32);
            let tf = v["tf"]
                .as_array()
                .unwrap()
                .iter()
                .map(|x| x.as_u64().unwrap() as u32);
            (
                v["id"].as_u64().unwrap(),
                v["note"].as_u64().unwrap(),
                kwfeed::pack(terms.zip(tf)),
            )
        })
        .collect();
    let mut c = db();
    let t0 = Instant::now();
    let write = |c: &mut Client,
                 u: &Uuid,
                 v: &Uuid,
                 docs: &mut dyn Iterator<Item = (Uuid, Uuid, Vec<u8>)>| {
        let mut t = c.transaction().unwrap();
        let mut n = 0;
        for (note, point, terms) in docs {
            insert_feed(
                &mut t,
                u,
                kwfeed::UPSERT,
                Some(v),
                Some(&note),
                Some(&point),
                1,
                Some(&terms),
            );
            n += 1;
            if n % 5000 == 0 {
                t.commit().unwrap();
                t = c.transaction().unwrap();
            }
        }
        t.commit().unwrap();
    };
    for rep in 0..reps as u64 {
        let mut it = rows.iter().map(|(id, note, terms)| {
            (
                Uuid::from_u64_pair(0xe7a1, (rep << 32) | note),
                Uuid::from_u64_pair(rep, *id),
                terms.clone(),
            )
        });
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
            let remapped = kwfeed::unpack(terms).unwrap().into_iter().map(|(t, n)| {
                (
                    fnv(&[u.as_bytes().as_slice(), &t.to_le_bytes()].concat()) as u32,
                    n,
                )
            });
            (
                Uuid::from_u64_pair(i, *note),
                Uuid::from_u128(rand::random()),
                kwfeed::pack(remapped),
            )
        });
        write(&mut c, &u, &v, &mut it);
    }
    println!(
        "{}",
        json!({"eval_user": user, "vault": vault, "shard": target, "chunks": rows.len() * reps,
                          "fillers": fillers, "secs": t0.elapsed().as_secs_f64()})
    );
}

fn shard_dir(i: usize) -> PathBuf {
    PathBuf::from(env("KW_DATA", "/data/kw"))
        .join("g1")
        .join(format!("s{i:03}"))
}

/// Index (all shards, read from disk) vs truth_chunks: same live point set,
/// same terms per point (fnv of the packed column), no point twice, and
/// every user's maintained stats equal to a scan of its live docs.
fn verify() {
    let mut seen: HashMap<Uuid, u64> = HashMap::new();
    let mut dups = 0;
    let mut stats_off = 0;
    let mut c = db();
    let users: Vec<Uuid> = c
        .query("SELECT user_id FROM truth_users", &[])
        .unwrap()
        .iter()
        .map(|r| r.get(0))
        .collect();
    let truth_stats: HashMap<Uuid, (u64, u64)> = c
        .query("SELECT user_id, terms FROM truth_chunks", &[])
        .unwrap()
        .iter()
        .fold(HashMap::new(), |mut m, r| {
            let len: u64 = kwfeed::unpack(r.get::<_, &[u8]>(1))
                .unwrap()
                .iter()
                .map(|p| p.1 as u64)
                .sum();
            let e = m.entry(r.get(0)).or_insert((0, 0));
            e.0 += 1;
            e.1 += len;
            m
        });
    for i in 0..SHARDS {
        let s = Shard::open(&shard_dir(i)).unwrap();
        for (p, _len, crc) in s.dump() {
            if seen.insert(p, crc).is_some() {
                dups += 1;
            }
        }
        for u in users.iter().filter(|u| shard_of(u) == i) {
            if s.user_stats(u) != truth_stats.get(u).copied().unwrap_or_default() {
                stats_off += 1;
            }
        }
    }
    let truth: HashMap<Uuid, u64> = c
        .query("SELECT point_id, terms FROM truth_chunks", &[])
        .unwrap()
        .iter()
        .map(|r| (r.get(0), fnv(r.get::<_, &[u8]>(1))))
        .collect();
    let missing = truth.keys().filter(|p| !seen.contains_key(p)).count();
    let extra = seen.keys().filter(|p| !truth.contains_key(p)).count();
    eprintln!(
        "missing sample: {:?}",
        truth
            .keys()
            .filter(|p| !seen.contains_key(p))
            .take(3)
            .collect::<Vec<_>>()
    );
    eprintln!(
        "extra sample: {:?}",
        seen.keys()
            .filter(|p| !truth.contains_key(p))
            .take(3)
            .collect::<Vec<_>>()
    );
    let stale = truth
        .iter()
        .filter(|(p, crc)| seen.get(p).is_some_and(|c| c != *crc))
        .count();
    println!(
        "{}",
        json!({"truth": truth.len(), "index": seen.len(), "missing": missing, "extra": extra,
                          "stale_content": stale, "duplicates": dups, "users": users.len(), "stats_mismatch": stats_off})
    );
    if missing + extra + stale + dups + stats_off > 0 {
        std::process::exit(1);
    }
}

/// Bytes on disk per shard directory and doc counts, for the size figure.
fn du() {
    let p = shard_dir(env_n("KW_SHARD", 0));
    let mut by: HashMap<String, u64> = HashMap::new();
    for e in std::fs::read_dir(&p).unwrap() {
        let e = e.unwrap();
        let name = e.file_name().into_string().unwrap();
        let ext = name.rsplit('.').next().unwrap_or("").to_string();
        *by.entry(ext).or_default() += e.metadata().unwrap().len();
    }
    let s = Shard::open(&p).unwrap();
    let searcher = s.reader.searcher();
    let docs: u64 = searcher
        .segment_readers()
        .iter()
        .map(|r| r.num_docs() as u64)
        .sum();
    println!(
        "{}",
        json!({"bytes": by, "total": by.values().sum::<u64>(), "alive_docs": docs, "segments": searcher.segment_readers().len()})
    );
}

/// HTTPS client trusting KW_CA_FILE (the service's own test CA).
fn agent() -> ureq::Agent {
    let mut roots = rustls::RootCertStore::empty();
    let pem = std::fs::read(env("KW_CA_FILE", "/secrets/ca.crt")).unwrap();
    for c in rustls_pemfile::certs(&mut pem.as_slice()) {
        roots.add(c.unwrap()).unwrap();
    }
    let tls = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_root_certificates(roots)
    .with_no_client_auth();
    ureq::AgentBuilder::new().tls_config(Arc::new(tls)).build()
}

fn search_token(user: &Uuid, vaults: &[Uuid]) -> String {
    token(&json!({"s": "search", "u": user, "v": vaults}).to_string())
}

fn post(agent: &ureq::Agent, url: &str, tok: &str, body: &str) -> Value {
    agent
        .post(&format!("{url}/search"))
        .set("authorization", &format!("Bearer {tok}"))
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

/// `bench <queries.json> <mode> <out.json>`; queries.json = {"queries":
/// [{"qid", "set", "terms"}]}. Modes: quality (every query once, top 40,
/// run file in the keyword bench's format), warm (KW_PASSES passes,
/// client-side ms over keep-alive HTTPS), cold (KW_N queries once, run right
/// after a restart with the page cache evicted). Filters: KW_INCLUDE /
/// KW_EXCLUDE = number of note ids, sent base64.
fn bench(args: &[String]) {
    let qs: Value = serde_json::from_str(&std::fs::read_to_string(&args[0]).unwrap()).unwrap();
    let mode = args[1].as_str();
    let url = env("KW_URL", "https://kwsearch:7700");
    let user: Uuid = env("KW_EVAL_USER", "00000000-0000-4000-8000-00000000e7a1")
        .parse()
        .unwrap();
    let vault = Uuid::from_u64_pair(fnv(user.as_bytes()), 0);
    let reps = env_n("KW_REPS", 1) as u64;
    let notes = env_n("KW_NOTES", 2219) as u64;
    let mut rng = StdRng::seed_from_u64(3);
    let mut pick = |n: usize| -> Vec<Uuid> {
        let mut s = HashSet::new();
        while s.len() < n {
            s.insert(Uuid::from_u64_pair(
                0xe7a1,
                (rng.random_range(0..reps.max(1)) << 32) | rng.random_range(0..notes),
            ));
        }
        s.into_iter().collect()
    };
    let (inc, exc) = (pick(env_n("KW_INCLUDE", 0)), pick(env_n("KW_EXCLUDE", 0)));
    let enc = |ids: &[Uuid]| {
        base64::engine::general_purpose::STANDARD
            .encode(ids.iter().flat_map(|u| *u.as_bytes()).collect::<Vec<u8>>())
    };
    let mut base = json!({"limit": env_n("KW_LIMIT", 40)});
    if !inc.is_empty() {
        base["include_b64"] = json!(enc(&inc));
    }
    if !exc.is_empty() {
        base["exclude_b64"] = json!(enc(&exc));
    }
    let agent = agent();
    let tok = search_token(&user, &[vault]);
    let all: Vec<(String, String, Vec<u32>)> = qs["queries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|q| {
            (
                q["qid"].as_str().unwrap().into(),
                q["set"].as_str().unwrap_or("q").into(),
                q["terms"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|t| t.as_u64().unwrap() as u32)
                    .collect(),
            )
        })
        .collect();
    let body = |terms: &[u32]| {
        let mut b = base.clone();
        b["terms"] = json!(terms);
        b.to_string()
    };
    let out = match mode {
        "quality" => {
            let runs: serde_json::Map<String, Value> = all
                .iter()
                .map(|(qid, _, terms)| {
                    let r = post(&agent, &url, &tok, &body(terms));
                    let ids: Vec<u64> = r["hits"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|h| {
                            h[0].as_str()
                                .unwrap()
                                .parse::<Uuid>()
                                .unwrap()
                                .as_u64_pair()
                                .1
                        })
                        .collect();
                    (qid.clone(), json!(ids))
                })
                .collect();
            json!({"unit": "chunk", "runs": runs})
        }
        "warm" | "cold" => {
            let passes = if mode == "warm" {
                env_n("KW_PASSES", 3)
            } else {
                1
            };
            let n = if mode == "cold" {
                env_n("KW_N", 60)
            } else {
                all.len()
            };
            let mut ms_all: Vec<f64> = Vec::new();
            for _ in 0..passes {
                for (_, _, terms) in all.iter().skip(env_n("KW_SKIP", 0)).take(n) {
                    let b = body(terms);
                    let t = Instant::now();
                    post(&agent, &url, &tok, &b);
                    ms_all.push(t.elapsed().as_secs_f64() * 1e3);
                }
            }
            json!({"mode": mode, "include": inc.len(), "exclude": exc.len(), "lat_ms": pct(&mut ms_all), "samples": ms_all})
        }
        _ => panic!("mode"),
    };
    std::fs::write(&args[2], serde_json::to_string_pretty(&out).unwrap()).unwrap();
    if mode != "quality" {
        let mut o = out.clone();
        o.as_object_mut().unwrap().remove("samples");
        println!("{o}");
    }
}

fn search_ids(
    agent: &ureq::Agent,
    url: &str,
    user: &Uuid,
    vault: &Uuid,
    terms: &[u32],
) -> Vec<Uuid> {
    let r = post(
        agent,
        url,
        &search_token(user, &[*vault]),
        &json!({"terms": terms, "limit": 100}).to_string(),
    );
    r["hits"]
        .as_array()
        .unwrap()
        .iter()
        .map(|h| h[0].as_str().unwrap().parse().unwrap())
        .collect()
}

fn wait_rounds() {
    std::thread::sleep(Duration::from_millis(env_n("KW_WAIT_MS", 2500) as u64));
}

/// (1) A lower xid committing after a higher one is still applied, and the
/// reader holds its cursor below the open transaction meanwhile. (2) A late
/// upsert (higher xid, committed BEFORE a delete_user / delete_vault with a
/// lower xid) never resurrects docs: the tombstone drops it. (3, with
/// KW_LATE_USER after a restart) tombstones survived the restart.
/// (4) `pg_current_xact_id()` inside a savepoint returns the top-level xid.
fn xidtest() {
    let url = env("KW_URL", "https://kwsearch:7700");
    let agent = agent();
    let run = Uuid::from_u128(rand::random()).as_u64_pair().0;
    let terms = |u: &Uuid| kwfeed::pack([(fnv(u.as_bytes()) as u32, 2)]);
    let term = |u: &Uuid| vec![fnv(u.as_bytes()) as u32];
    let mut report = serde_json::Map::new();

    if let Ok(u) = std::env::var("KW_LATE_USER") {
        let u: Uuid = u.parse().unwrap();
        let (hi, lo) = u.as_u64_pair();
        let (v, n, p) = (
            Uuid::from_u64_pair(hi, lo + 1),
            Uuid::from_u64_pair(hi, lo + 2),
            Uuid::from_u64_pair(hi, lo + 9),
        );
        let mut c = db();
        let mut t = c.transaction().unwrap();
        insert_feed(
            &mut t,
            &u,
            kwfeed::UPSERT,
            Some(&v),
            Some(&n),
            Some(&p),
            9,
            Some(&terms(&u)),
        );
        t.commit().unwrap();
        wait_rounds();
        let after = search_ids(&agent, &url, &u, &v, &term(&u));
        println!(
            "{}",
            json!({"upsert_after_restart_for_deleted_user": u, "visible": after.len(), "pass": after.is_empty()})
        );
        std::process::exit(if after.is_empty() { 0 } else { 1 });
    }

    let (u, v, n) = (
        Uuid::from_u64_pair(run, 1),
        Uuid::from_u64_pair(run, 2),
        Uuid::from_u64_pair(run, 3),
    );
    let (pa, pb) = (Uuid::from_u64_pair(run, 10), Uuid::from_u64_pair(run, 11));
    let (mut ca, mut cb, mut probe) = (db(), db(), db());
    let mut ta = ca.transaction().unwrap();
    insert_feed(
        &mut ta,
        &u,
        kwfeed::UPSERT,
        Some(&v),
        Some(&n),
        Some(&pa),
        1,
        Some(&terms(&u)),
    );
    let seq_a: i64 = ta
        .query_one(
            "SELECT max(seq) FROM keyword_feed WHERE point_id=$1",
            &[&pa],
        )
        .unwrap()
        .get(0);
    let mut tb = cb.transaction().unwrap();
    insert_feed(
        &mut tb,
        &u,
        kwfeed::UPSERT,
        Some(&v),
        Some(&n),
        Some(&pb),
        1,
        Some(&terms(&u)),
    );
    let seq_b: i64 = tb
        .query_one(
            "SELECT max(seq) FROM keyword_feed WHERE point_id=$1",
            &[&pb],
        )
        .unwrap()
        .get(0);
    tb.commit().unwrap();
    wait_rounds();
    let mid = search_ids(&agent, &url, &u, &v, &term(&u));
    let naive_max: i64 = probe
        .query_one("SELECT max(seq) FROM keyword_feed", &[])
        .unwrap()
        .get(0);
    ta.commit().unwrap();
    wait_rounds();
    let after = search_ids(&agent, &url, &u, &v, &term(&u));
    let ok1 =
        !mid.contains(&pb) && !mid.contains(&pa) && after.contains(&pa) && after.contains(&pb);
    report.insert(
        "lower_xid_commits_later".into(),
        json!({"seq_a": seq_a, "seq_b": seq_b,
        "naive_skips_a": naive_max >= seq_b && seq_a < seq_b, "visible_while_a_open": mid.len(),
        "visible_after_a_commits": after.len(), "pass": ok1}),
    );

    let mut ok2 = true;
    for (label, op) in [
        ("delete_user", kwfeed::DELETE_USER),
        ("delete_vault", kwfeed::DELETE_VAULT),
    ] {
        let k = if op == kwfeed::DELETE_USER { 100 } else { 200 };
        let (u, v, n) = (
            Uuid::from_u64_pair(run, k),
            Uuid::from_u64_pair(run, k + 1),
            Uuid::from_u64_pair(run, k + 2),
        );
        let (p0, late) = (
            Uuid::from_u64_pair(run, k + 3),
            Uuid::from_u64_pair(run, k + 4),
        );
        let mut c0 = db();
        let mut t0 = c0.transaction().unwrap();
        insert_feed(
            &mut t0,
            &u,
            kwfeed::UPSERT,
            Some(&v),
            Some(&n),
            Some(&p0),
            1,
            Some(&terms(&u)),
        );
        t0.commit().unwrap();
        wait_rounds();
        let before = search_ids(&agent, &url, &u, &v, &term(&u));
        let (mut cc, mut cd) = (db(), db());
        let mut tc = cc.transaction().unwrap();
        let xid_c: String = tc
            .query_one("SELECT pg_current_xact_id()::text", &[])
            .unwrap()
            .get(0);
        let mut td = cd.transaction().unwrap();
        insert_feed(
            &mut td,
            &u,
            kwfeed::UPSERT,
            Some(&v),
            Some(&n),
            Some(&late),
            2,
            Some(&terms(&u)),
        );
        let xid_d: String = td
            .query_one("SELECT pg_current_xact_id()::text", &[])
            .unwrap()
            .get(0);
        td.commit().unwrap();
        insert_feed(
            &mut tc,
            &u,
            op,
            Some(&v).filter(|_| op == kwfeed::DELETE_VAULT),
            None,
            None,
            0,
            None,
        );
        tc.commit().unwrap();
        wait_rounds();
        let after = search_ids(&agent, &url, &u, &v, &term(&u));
        let ok = before == vec![p0]
            && after.is_empty()
            && xid_c.parse::<u64>().unwrap() < xid_d.parse::<u64>().unwrap();
        ok2 &= ok;
        report.insert(
            label.into(),
            json!({"before": before.len(), "after": after.len(), "pass": ok, "user": u}),
        );
    }

    // (4) Nested `with_tenant` transactions are savepoints; the feed row's
    // xid default must be the top-level xid, or commit-safe reads break.
    let mut c = db();
    let mut t = c.transaction().unwrap();
    let top: String = t
        .query_one("SELECT pg_current_xact_id()::text", &[])
        .unwrap()
        .get(0);
    let mut sp = t.transaction().unwrap();
    let inner: String = sp
        .query_one("SELECT pg_current_xact_id()::text", &[])
        .unwrap()
        .get(0);
    sp.commit().unwrap();
    t.rollback().unwrap();
    let ok4 = top == inner;
    report.insert("savepoint_xid_is_top_level".into(), json!({"pass": ok4}));

    report.insert("pass".into(), json!(ok1 && ok2 && ok4));
    println!("{}", Value::Object(report));
    if !(ok1 && ok2 && ok4) {
        std::process::exit(1);
    }
}
