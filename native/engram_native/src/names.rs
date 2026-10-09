//! Per-vault name index: decrypted note paths and titles held in native
//! memory behind a resource handle, searched here, so plaintext names never
//! become Elixir terms (no heap copies, no crash dumps, nothing in ETS).
//!
//! Built once from the vault's encrypted name columns under one key schedule
//! (`OpenKey`), then patched in place as notes change.

use engram_core::envelope::{OpenKey, Opened};
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Config, Matcher, Utf32Str};
use std::collections::HashMap;
use std::sync::RwLock;

/// Names are short; a zstd body declaring more than this is refused.
const NAME_INFLATE_MAX: usize = 64 * 1024;
/// Rough per-entry overhead (key, two Strings, map slot) for the size estimate.
const ENTRY_OVERHEAD: usize = 96;

pub struct Entry {
    path: String,
    title: String,
}

pub struct NameIndex {
    entries: RwLock<HashMap<[u8; 16], Entry>>,
}

/// One encrypted row: raw 16-byte id, whether its AAD binds the row id
/// (`dek_version >= 2`), path ciphertext + nonce, optional title.
pub struct Row<'a> {
    pub id: &'a [u8],
    pub bind: bool,
    pub path: (&'a [u8], &'a [u8]),
    pub title: Option<(&'a [u8], &'a [u8])>,
}

fn open_name(key: &OpenKey, prefix: &[u8], row: &Row, field: (&[u8], &[u8])) -> Option<String> {
    let mut aad = Vec::with_capacity(prefix.len() + row.id.len());
    if row.bind {
        aad.extend_from_slice(prefix);
        aad.extend_from_slice(row.id);
    }
    let bytes = match key
        .open(field.0, field.1, &aad, NAME_INFLATE_MAX, |n| {
            Some(vec![0u8; n])
        })
        .ok()?
    {
        Opened::InPlace(mut buf, skip) => {
            buf.drain(..skip);
            buf
        }
        Opened::Inflated(v) => v,
        Opened::OverBudget => return None,
    };
    String::from_utf8(bytes).ok()
}

fn id16(id: &[u8]) -> Option<[u8; 16]> {
    id.try_into().ok()
}

impl NameIndex {
    /// `None` if any row fails to authenticate or decode: the Elixir read
    /// path raises on the same rows, and a partial index would hide notes.
    pub fn build(
        key: &[u8],
        path_prefix: &[u8],
        title_prefix: &[u8],
        rows: &[Row],
    ) -> Option<Self> {
        let key = OpenKey::new(key).ok()?;
        let mut entries = HashMap::with_capacity(rows.len());
        for row in rows {
            let path = open_name(&key, path_prefix, row, row.path)?;
            let title = match row.title {
                Some(t) => open_name(&key, title_prefix, row, t)?,
                None => String::new(),
            };
            entries.insert(id16(row.id)?, Entry { path, title });
        }
        Some(Self {
            entries: RwLock::new(entries),
        })
    }

    pub fn bytes(&self) -> usize {
        let e = self.entries.read().unwrap_or_else(|p| p.into_inner());
        e.values()
            .map(|x| x.path.len() + x.title.len() + ENTRY_OVERHEAD)
            .sum()
    }

    /// Insert or update. An empty title keeps the current one: meta-only
    /// broadcasts (folder renames) carry the path but no title.
    pub fn put(&self, id: &[u8], path: &str, title: &str) -> bool {
        let Some(id) = id16(id) else { return false };
        let mut e = self.entries.write().unwrap_or_else(|p| p.into_inner());
        let title = match (title.is_empty(), e.get(&id)) {
            (true, Some(old)) => old.title.clone(),
            _ => title.to_owned(),
        };
        e.insert(
            id,
            Entry {
                path: path.to_owned(),
                title,
            },
        );
        true
    }

    /// Applies `(is_put, id, path, title)` events in order under ONE write
    /// lock, so a burst of changes costs one lock and one NIF call.
    pub fn patch(&self, events: &[(bool, &[u8], &str, &str)]) {
        for (is_put, id, path, title) in events {
            if *is_put {
                self.put(id, path, title);
            } else {
                self.delete(id, path);
            }
        }
    }

    /// Removes the entry only while it still holds `path`: a rename
    /// broadcasts an upsert of the new path, then a delete of the old path
    /// under the SAME id, and that delete must not drop the renamed entry.
    pub fn delete(&self, id: &[u8], path: &str) {
        let Some(id) = id16(id) else { return };
        let mut e = self.entries.write().unwrap_or_else(|p| p.into_inner());
        if e.get(&id).is_some_and(|x| x.path == path) {
            e.remove(&id);
        }
    }

    /// Paths matching `query` (fuzzy over path and title, prefix and
    /// substring score highest), best first, at most `limit`; plus the total
    /// match count. An empty query lists paths alphabetically.
    pub fn search(&self, query: &str, limit: usize) -> (Vec<String>, usize) {
        let e = self.entries.read().unwrap_or_else(|p| p.into_inner());
        if query.trim().is_empty() {
            let mut all: Vec<&str> = e.values().map(|x| x.path.as_str()).collect();
            all.sort_unstable();
            let total = all.len();
            return (
                all.into_iter().take(limit).map(str::to_owned).collect(),
                total,
            );
        }
        let pattern = Pattern::parse(query, CaseMatching::Ignore, Normalization::Smart);
        let mut matcher = Matcher::new(Config::DEFAULT.match_paths());
        let mut buf = Vec::new();
        let mut hits: Vec<(u32, &str)> = e
            .values()
            .filter_map(|x| {
                let p = pattern.score(Utf32Str::new(&x.path, &mut buf), &mut matcher);
                let t = pattern.score(Utf32Str::new(&x.title, &mut buf), &mut matcher);
                p.max(t).map(|s| (s, x.path.as_str()))
            })
            .collect();
        hits.sort_unstable_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(b.1)));
        let total = hits.len();
        (
            hits.into_iter()
                .take(limit)
                .map(|(_, p)| p.to_owned())
                .collect(),
            total,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use engram_core::envelope::{seal, Mode};

    const K: [u8; 32] = [9; 32];

    fn sealed(plain: &str, aad: &[u8]) -> (Vec<u8>, Vec<u8>) {
        seal(plain.as_bytes(), &K, aad, Mode::Auto, [3; 12], |n| {
            Some(vec![0; n])
        })
        .unwrap()
    }

    fn index(names: &[(&str, &str)]) -> NameIndex {
        let ids: Vec<[u8; 16]> = (0..names.len())
            .map(|i| (i as u128).to_be_bytes())
            .collect();
        let data: Vec<_> = names
            .iter()
            .zip(&ids)
            .map(|((p, t), id)| {
                let pa = [&b"notes\0path\0"[..], id].concat();
                let ta = [&b"notes\0title\0"[..], id].concat();
                (sealed(p, &pa), sealed(t, &ta))
            })
            .collect();
        let rows: Vec<Row> = data
            .iter()
            .zip(&ids)
            .map(|(((pc, pn), (tc, tn)), id)| Row {
                id,
                bind: true,
                path: (pc, pn),
                title: Some((tc, tn)),
            })
            .collect();
        NameIndex::build(&K, b"notes\0path\0", b"notes\0title\0", &rows).unwrap()
    }

    #[test]
    fn finds_by_prefix_substring_fuzzy_and_title() {
        let i = index(&[
            ("Projects/Engram.md", "Engram"),
            ("Daily/2026-10-09.md", "Thursday"),
            ("Ideas/Graph view.md", "Graphs"),
        ]);
        assert_eq!(i.search("engr", 10).0, ["Projects/Engram.md"]);
        assert_eq!(i.search("ENGRAM", 10).0, ["Projects/Engram.md"]);
        assert_eq!(i.search("prjengr", 10).0, ["Projects/Engram.md"]);
        assert_eq!(i.search("thursday", 10).0, ["Daily/2026-10-09.md"]);
        assert_eq!(i.search("zzz", 10), (vec![], 0));
        assert_eq!(i.search("", 2).1, 3);
        assert_eq!(i.search("", 2).0.len(), 2);
    }

    #[test]
    fn put_and_delete_patch_in_place() {
        let i = index(&[("A.md", "a")]);
        assert!(i.put(&0u128.to_be_bytes(), "Renamed.md", ""));
        assert_eq!(i.search("renamed", 10).0, ["Renamed.md"]);
        assert_eq!(
            i.search("a", 10).0,
            ["Renamed.md"],
            "empty title keeps the old one"
        );
        assert!(i.put(&[7; 16], "New.md", "new"));
        i.delete(&0u128.to_be_bytes(), "A.md");
        assert_eq!(
            i.search("", 10).0.len(),
            2,
            "a stale-path delete is a rename's tail"
        );
        i.delete(&0u128.to_be_bytes(), "Renamed.md");
        assert_eq!(i.search("", 10).0, ["New.md"]);
        assert!(!i.put(b"short", "x", "x"));
    }

    #[test]
    fn wrong_key_or_aad_fails_the_whole_build() {
        let (pc, pn) = sealed("A.md", b"notes\0path\0AAAAAAAAAAAAAAAA");
        let row = Row {
            id: b"BBBBBBBBBBBBBBBB",
            bind: true,
            path: (&pc, &pn),
            title: None,
        };
        assert!(NameIndex::build(&K, b"notes\0path\0", b"", &[row]).is_none());
        let row = Row {
            id: b"AAAAAAAAAAAAAAAA",
            bind: true,
            path: (&pc, &pn),
            title: None,
        };
        assert!(NameIndex::build(&[1; 32], b"notes\0path\0", b"", &[row]).is_none());
    }

    #[test]
    fn legacy_rows_open_with_empty_aad() {
        let (pc, pn) = sealed("Old.md", b"");
        let row = Row {
            id: &[1; 16],
            bind: false,
            path: (&pc, &pn),
            title: None,
        };
        let i = NameIndex::build(&K, b"notes\0path\0", b"", &[row]).unwrap();
        assert_eq!(i.search("old", 10).0, ["Old.md"]);
    }

    #[test]
    fn search_is_linear_at_50k() {
        let names: Vec<(String, String)> = (0..50_000)
            .map(|i| {
                (
                    format!("Folder {}/Note number {i}.md", i % 97),
                    format!("Title {i}"),
                )
            })
            .collect();
        let refs: Vec<(&str, &str)> = names
            .iter()
            .map(|(a, b)| (a.as_str(), b.as_str()))
            .collect();
        let t = std::time::Instant::now();
        let i = index(&refs);
        let built = t.elapsed();
        let t = std::time::Instant::now();
        let (hits, total) = i.search("note 4242", 100);
        let searched = t.elapsed();
        eprintln!("50k: build {built:?}, search {searched:?}, {total} hits");
        assert!(hits.iter().any(|h| h.contains("4242")));
        // Catches a complexity blowup, not a slow runner.
        assert!(searched.as_millis() < 2_000);
    }
}
