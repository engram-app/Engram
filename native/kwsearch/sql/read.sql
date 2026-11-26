SELECT seq, xid::text AS xid_text, user_id, index_set, op, vault_id, note_id, point_id, stamp, terms, keep
  FROM keyword_feed
  WHERE (xid, seq) > ($1::text::xid8, $2) AND xid < $3::text::xid8
  ORDER BY xid, seq LIMIT $4
