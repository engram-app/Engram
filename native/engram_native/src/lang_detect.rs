//! Language ID for `Engram.KeywordIndex.LangDetect`: lingua-rs with the
//! options the `lingua` hex package was called with (all Latin-script
//! languages, low accuracy mode, models loaded lazily), but ONE detector for
//! the life of the node. The hex NIF built a new one on every call.
//!
//! Low accuracy mode reads only the trigram models: ~55 MB resident for all
//! Latin-script languages, against ~945 MB in full mode, which OOM-looped
//! the 1 GB task (#891/#892). The models live in lingua's own process-global
//! maps, allocated through our allocator, so `:erlang.memory(:system)` sees
//! them.
//!
//! Single text only: lingua's rayon use is confined to the `*_in_parallel`
//! and preload methods, which this never calls, so no thread pool starts.
use lingua::{Language, LanguageDetector, LanguageDetectorBuilder};
use std::sync::OnceLock;

static DETECTOR: OnceLock<LanguageDetector> = OnceLock::new();

fn detector() -> &'static LanguageDetector {
    DETECTOR.get_or_init(|| {
        LanguageDetectorBuilder::from_all_languages_with_latin_script()
            .with_low_accuracy_mode()
            .build()
    })
}

/// The most likely language and its confidence. Every language is scored,
/// so there is always one; with nothing to score all are 0.0 and the order
/// among them is arbitrary.
pub fn top(text: &str) -> (Language, f64) {
    detector()
        .compute_language_confidence_values(text)
        .into_iter()
        .next()
        .expect("a detector built from many languages scores all of them")
}

/// The hex package's atom for a language: its lowercase name.
pub fn name(language: Language) -> String {
    language.to_string().to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_common_languages() {
        let (lang, conf) = top("the deployment process was tested today");
        assert_eq!(name(lang), "english");
        assert!(conf > 0.4);
        assert_eq!(name(top("die Bereitstellung wurde getestet").0), "german");
    }

    #[test]
    fn nothing_to_score_is_zero() {
        assert_eq!(top("").1, 0.0);
        assert_eq!(top("1234 !!! 😀").1, 0.0);
    }
}
