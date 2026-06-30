# ci/fingerprint/groups.sh: single source of truth for CI input groups.
# group_paths <group>  -> echoes the pathspecs for git ls-tree
# group_hash  <group> <beam_tag> -> sha256 of tracked content under those paths (+ beam tag)
group_paths() {
  case "$1" in
    elixir-src)  echo "lib config mix.lock" ;;        # mix.exs handled separately (version-stripped)
    unit-tests)  echo "test" ;;
    migrations)  echo "priv/repo/migrations priv/repo/seeds.exs" ;;
    e2e-harness) echo "e2e" ;;
    frontend)    echo "frontend" ;;
    docker-image) echo "Dockerfile entrypoint.sh .dockerignore" ;;
    lint-config) echo ".credo.exs .sobelow-conf .formatter.exs" ;;
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
