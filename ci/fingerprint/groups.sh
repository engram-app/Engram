# ci/fingerprint/groups.sh: single source of truth for CI input groups.
# group_paths <group>  -> echoes the pathspecs for git ls-tree
# group_hash  <group> <beam_tag> -> sha256 of tracked content under those paths (+ beam tag)
group_paths() {
  case "$1" in
    elixir-src)  echo "lib config mix.lock" ;;        # mix.exs handled separately (version-stripped)
    unit-tests)  echo "test" ;;
    # Whole priv/, not just migrations: priv/legal (ToS manifests the legal
    # seeder loads at boot), priv/static (SPA assets), priv/gettext, seeds, and
    # structure.sql all affect unit-tests / the booted release. Legacy
    # BACKEND_HASH hashed all of priv; under-including here silently skips jobs.
    priv)        echo "priv" ;;
    e2e-harness) echo "e2e" ;;
    frontend)    echo "frontend" ;;
    # rel/ is COPY'd into the release image (Dockerfile `COPY rel rel`: env.sh.eex
    # cluster gate + RELEASE_NODE). ci/compose*.yml drive every e2e/storage stack.
    # Both were in BACKEND_HASH; dropping them lets a stack/release-env change skip.
    docker-image) echo "Dockerfile entrypoint.sh .dockerignore rel ci/compose.yml ci/compose.local.yml ci/compose.database.yml" ;;
    # .dialyzer_ignore.exs gates the lint job's dialyzer step (a fatal check).
    lint-config) echo ".credo.exs .sobelow-conf .formatter.exs .dialyzer_ignore.exs" ;;
    # The CI logic itself: a change to the workflow or the fingerprint scripts
    # must bust EVERY job's hash (mirrors BACKEND_HASH including verify.yml), so
    # a CI-config change is never skipped by a stale per-job marker.
    ci-meta)     echo ".github/workflows/verify.yml ci/fingerprint" ;;
    *) echo "unknown group: $1" >&2; return 2 ;;
  esac
}
group_hash() {
  local group="$1" beam="${2:-}" paths
  paths=$(group_paths "$group") || return 2
  { git ls-tree -r HEAD -- $paths 2>/dev/null
    if [ "$group" = elixir-src ]; then
      grep -vE '^[[:space:]]*version: "[0-9]+\.[0-9]+\.[0-9]+"' mix.exs | sha256sum
    fi
    echo "beam:$beam"
  } | sha256sum | cut -d' ' -f1
}
