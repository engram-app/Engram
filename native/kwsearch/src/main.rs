//! kwsearch: the Tantivy keyword service (search storage roadmap P2).
//! `kwsearch serve` runs it; the other subcommands are the integration
//! harness (`tools`).

mod feed;
mod http;
mod metrics;
mod row;
mod shard;
#[cfg(test)]
mod shard_tests;
mod token;
#[cfg(feature = "harness")]
mod tools;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

pub fn env(k: &str, default: &str) -> String {
    std::env::var(k).unwrap_or_else(|_| default.to_string())
}

pub fn env_n(k: &str, default: usize) -> usize {
    match std::env::var(k) {
        Ok(v) => v.parse().unwrap_or_else(|_| panic!("{k} must be a number")),
        Err(_) => default,
    }
}

fn read_secret(var: &str) -> String {
    let path = std::env::var(var).unwrap_or_else(|_| panic!("{var} is required"));
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("{var}: {e}"))
        .trim()
        .to_string()
}

/// Hands freed heap back to the OS after writers close. glibc keeps a
/// closed writer's arenas mapped (the POC's writer process kept 2.3-5.2 GB
/// after every writer closed; P2 task 4b).
pub fn trim_heap() {
    #[cfg(all(target_os = "linux", target_env = "gnu"))]
    // SAFETY: malloc_trim only releases free memory at the top of the heap
    // and in arenas; it touches no live allocation.
    unsafe {
        libc::malloc_trim(0);
    }
}

const DAY: u64 = 86_400;

fn serve() {
    let dir = PathBuf::from(env("KW_DATA", "/data/kw"));
    let gens: Vec<i16> = env("KW_GENERATIONS", "1")
        .split(',')
        .map(|g| {
            g.trim()
                .parse()
                .expect("KW_GENERATIONS: comma-separated index set numbers")
        })
        .collect();
    let index = Arc::new(feed::Index::open(&dir, &gens).expect("open index"));
    let stats = Arc::new(feed::Stats::default());
    let snapshot_days = env_n("KW_SNAPSHOT_RETENTION_DAYS", 30) as u64;
    let tomb_days = env_n("KW_TOMBSTONE_TTL_DAYS", 30) as u64;
    // A tombstone must outlive every copy that could bring the account back:
    // a restored snapshot, a 48 h feed row (security F12).
    assert!(
        tomb_days >= snapshot_days.max(2),
        "KW_TOMBSTONE_TTL_DAYS must be >= KW_SNAPSHOT_RETENTION_DAYS and >= 2"
    );
    let cfg = feed::Cfg {
        url: env("KW_FEED_URL", ""),
        password: std::env::var("KW_FEED_PASSWORD_FILE")
            .ok()
            .map(|_| read_secret("KW_FEED_PASSWORD_FILE")),
        ca_file: PathBuf::from(env("KW_FEED_CA_FILE", "/etc/kwsearch/rds-ca.pem")),
        batch: env_n("KW_BATCH", 1000) as i64,
        window: env_n("KW_WINDOW", 20_000),
        max_window: env_n("KW_MAX_WINDOW", 200_000),
        round: Duration::from_millis(env_n("KW_ROUND_MS", 1000) as u64),
        writer_mb: env_n("KW_WRITER_MB", 15),
        max_writers: env_n("KW_MAX_WRITERS", 32),
        writer_idle: Duration::from_secs(env_n("KW_WRITER_IDLE_S", 30) as u64),
        tomb_ttl_s: tomb_days * DAY,
        purge_after_s: env_n("KW_PURGE_AFTER_S", 7 * DAY as usize) as u64,
    };
    // Read-only node (benches; a later replica): serves the index on disk
    // as is, no feed loop. Never the default.
    let read_only = env("KW_READ_ONLY", "0") == "1";
    assert!(
        read_only || !cfg.url.is_empty(),
        "KW_FEED_URL is required (or KW_READ_ONLY=1)"
    );
    let keys = token::Keys::parse(&read_secret("KW_TOKEN_KEYS_FILE")).expect("KW_TOKEN_KEYS_FILE");
    let metrics_token = read_secret("KW_METRICS_TOKEN_FILE");
    assert!(
        metrics_token.len() >= 32,
        "KW_METRICS_TOKEN_FILE must hold at least 32 bytes"
    );
    let tls = server_tls(
        &env("KW_TLS_CERT", "/etc/kwsearch/tls.crt"),
        &env("KW_TLS_KEY", "/etc/kwsearch/tls.key"),
    );
    let app = http::App {
        index: index.clone(),
        stats: stats.clone(),
        keys: Arc::new(keys),
        metrics_token: Arc::new(metrics_token),
        writer_mb: cfg.writer_mb,
        tomb_ttl_s: cfg.tomb_ttl_s,
        read_only,
    };
    if read_only {
        stats
            .ready
            .store(true, std::sync::atomic::Ordering::Relaxed);
        stats
            .drained_at
            .store(feed::now(), std::sync::atomic::Ordering::Relaxed);
    } else {
        // A dead feed loop behind a live /search would serve an index that
        // silently stops moving: any panic in it exits the process instead.
        std::thread::spawn(move || {
            let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                feed::run(index, cfg, stats)
            }));
            let msg = r.err().and_then(|e| {
                e.downcast_ref::<String>()
                    .cloned()
                    .or_else(|| e.downcast_ref::<&str>().map(|s| s.to_string()))
            });
            eprintln!("feed loop died: {msg:?}");
            std::process::exit(70);
        });
    }
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(env_n("KW_HTTP_THREADS", 2))
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let addr: std::net::SocketAddr =
            env("KW_LISTEN", "0.0.0.0:7700").parse().expect("KW_LISTEN");
        eprintln!("kwsearch listening (TLS) on {addr}");
        axum_server::bind_rustls(addr, tls)
            .serve(http::router(app).into_make_service())
            .await
            .unwrap();
    });
}

/// rustls on the listener (security F6). No plaintext mode.
fn server_tls(cert: &str, key: &str) -> axum_server::tls_rustls::RustlsConfig {
    use std::io::BufReader;
    let certs: Vec<_> = rustls_pemfile::certs(&mut BufReader::new(
        std::fs::File::open(cert).expect("KW_TLS_CERT"),
    ))
    .collect::<Result<_, _>>()
    .expect("KW_TLS_CERT");
    let key = rustls_pemfile::private_key(&mut BufReader::new(
        std::fs::File::open(key).expect("KW_TLS_KEY"),
    ))
    .expect("KW_TLS_KEY")
    .expect("KW_TLS_KEY holds no key");
    let mut c = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(certs, key)
    .expect("TLS cert and key");
    c.alpn_protocols = vec![b"http/1.1".to_vec()];
    axum_server::tls_rustls::RustlsConfig::from_config(Arc::new(c))
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("serve") => serve(),
        #[cfg(feature = "harness")]
        Some(cmd) => tools::run(cmd, &args[1..]),
        #[cfg(not(feature = "harness"))]
        Some(cmd) => eprintln!("unknown command {cmd} (harness subcommands need --features harness)"),
        None => eprintln!("usage: kwsearch serve | schema | gen | burst | load-eval | verify | bench | xidtest | du"),
    }
}
