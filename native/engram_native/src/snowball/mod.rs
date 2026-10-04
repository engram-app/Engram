//! Snowball runtime + stemmers generated (Snowball 3.1.1, `snowball -rust`) from
//! the SAME `.sbl` sources `text_stemmer` ships (deps/text_stemmer/src/algorithms),
//! so stems match the Elixir encoder. Regenerate with native/engram_native/regen.sh; license in COPYING.
// Generated code assigns some flags it never reads.
#[allow(unused_assignments)]
pub mod algorithms;
mod among;
mod snowball_env;

pub use among::Among;
pub use snowball_env::SnowballEnv;
