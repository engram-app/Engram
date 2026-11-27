export KW_SUPER_URL="postgres://postgres:$(cat /secrets/pgpw)@kwpoc-pg:5432/postgres"
export KW_FEED_URL="postgres://kwsearch_feed:$(cat /secrets/feedpw)@kwpoc-pg:5432/postgres"
export BIN=/target/release/kwsearch
