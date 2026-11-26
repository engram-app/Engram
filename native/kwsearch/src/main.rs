//! kwsearch: Tantivy keyword service (POC). `kwsearch serve` runs it; the
//! other subcommands are the POC's test and bench tools.

mod feed;
mod http;
mod shard;
mod tools;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

pub fn env(k: &str, default: &str) -> String {
    std::env::var(k).unwrap_or_else(|_| default.to_string())
}

pub fn env_n(k: &str, default: usize) -> usize {
    env(k, &default.to_string()).parse().unwrap()
}

fn serve() {
    let dir = PathBuf::from(env("KW_DATA", "/data/kw"));
    let shards = Arc::new(feed::Shards::open(&dir));
    let stats = Arc::new(feed::Stats::default());
    let cfg = feed::Cfg {
        url: env("KW_FEED_URL", ""),
        batch: env_n("KW_BATCH", 1000) as i64,
        window: env_n("KW_WINDOW", 20_000),
        round: Duration::from_millis(env_n("KW_ROUND_MS", 1000) as u64),
        writer_mb: env_n("KW_WRITER_MB", 15),
        max_writers: env_n("KW_MAX_WRITERS", 32),
        writer_idle: Duration::from_secs(env_n("KW_WRITER_IDLE_S", 30) as u64),
    };
    let secret = std::fs::read_to_string(env("KW_SECRET_FILE", "/secrets/kwsecret")).expect("secret file");
    let app = http::App { shards: shards.clone(), stats: stats.clone(), secret: Arc::new(secret.trim().to_string()) };
    if !cfg.url.is_empty() {
        // A dead feed loop behind a live /search would serve an index that
        // silently stops moving: any panic in it exits the process instead.
        std::thread::spawn(move || {
            let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| feed::run(shards, cfg, stats)));
            eprintln!("feed loop died: {:?}", r.err().and_then(|e| e.downcast_ref::<String>().cloned()));
            std::process::exit(70);
        });
    }
    let rt = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(env_n("KW_HTTP_THREADS", 2))
        .enable_all()
        .build()
        .unwrap();
    rt.block_on(async {
        let l = tokio::net::TcpListener::bind(env("KW_LISTEN", "0.0.0.0:7700")).await.unwrap();
        eprintln!("kwsearch listening");
        axum::serve(l, http::router(app)).await.unwrap();
    });
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("serve") => serve(),
        Some(cmd) => tools::run(cmd, &args[1..]),
        None => eprintln!("usage: kwsearch serve | schema | gen | burst | load-eval | verify | bench | xidtest"),
    }
}
