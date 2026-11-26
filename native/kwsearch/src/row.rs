//! One `keyword_feed` row as the writer applies it.

use uuid::Uuid;

#[derive(Debug, Clone, Default)]
pub struct Row {
    pub seq: i64,
    pub xid: u64,
    /// xmax of the snapshot the row was read under: every transaction that
    /// committed before this row's did so with an xid below it. A note
    /// marker set by this row expires once the cursor passes it.
    pub xmax: u64,
    pub user: Uuid,
    pub gen: i16,
    pub op: i16,
    pub vault: Option<Uuid>,
    pub note: Option<Uuid>,
    pub point: Option<Uuid>,
    pub stamp: i64,
    pub terms: Option<Vec<u8>>,
    pub keep: Option<Vec<Uuid>>,
}
