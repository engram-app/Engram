#!/usr/bin/env bash
# test/scripts/redact_cmdline_test.sh
#
# The runner-diagnostics job (cron.yml) prints process command lines on
# self-hosted runners whose logs are PUBLIC. Other runners on the same host
# carry `--jitconfig <credential>` in argv, a live registration credential.
# Proves scripts/redact_cmdline.sh strips it, and that nothing CI runs
# (.github/, ci/, scripts/) prints full argv or process env without routing
# it through the redactor as the first pipeline stage.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REDACT="${REDACT:-$ROOT/scripts/redact_cmdline.sh}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

check() { # $1 = input line, $2 = secret that must not survive
  local out
  out=$(printf '%b\n' "$1" | bash "$REDACT")
  case "$out" in *"$2"*) fail "secret survived redaction: $out" ;; esac
  case "$out" in *REDACTED*) ;; *) fail "no [REDACTED] marker: $out" ;; esac
}

check '1234 Runner.Listener run --jitconfig ABC123secret' ABC123secret
check '1234 Runner.Listener run --jitconfig=ABC123secret --once' ABC123secret
check '1234 Runner.Listener run --jitconfig\tTABsecret' TABsecret
check '1234 Runner.Listener run --JITCONFIG UPsecret' UPsecret
check '1234 Runner.Listener run -jitconfig DASHsecret' DASHsecret
check '1 a --jitconfig AAAsecret; 2 b --jitconfig BBBsecret' BBBsecret
check './config.sh --url https://x --token TOKsecret' TOKsecret
check './config.sh --url https://x --pat PATsecret' PATsecret

# Lines without a credential pass through untouched.
plain='42 /usr/bin/Xvfb :99 -screen 0 1280x1024x24'
[ "$(printf '%s\n' "$plain" | bash "$REDACT")" = "$plain" ] || fail "mangled a clean line"

# Structural guard. Flags any non-comment line (plus its `\` / `|`
# continuations) that prints full argv or process env, unless
# scripts/redact_cmdline.sh is the FIRST pipeline stage (so nothing can
# truncate a secret into a partial, unmatchable fragment first).
scan() {
  awk '
    FNR==1 { open=0 }
    {
      hit = $0 !~ /^[[:space:]]*#/ && $0 !~ /docker ps/ && (                 \
        $0 ~ /(^|[^a-z])ps +-?[a-z]*[ef]([[:space:]]|$)/                  || \
        $0 ~ /(^|[^a-z])ps +[a-z]*x([[:space:]]|$)/                       || \
        $0 ~ /(^|[^a-z])ps [^|]*-?[a-zA-Z]*o +[^ |]*(cmd|args|command)/   || \
        $0 ~ /pgrep [^|]*(-[a-z]*a|--list-full)/                          || \
        $0 ~ /pstree +-[a-z]*a/                                           || \
        $0 ~ /systemctl[^|]* status/                                      || \
        $0 ~ /\/proc\/[^ ]*\/(cmdline|environ)/ )
      if (hit) { start=FILENAME":"FNR; chain=$0; open=1 }
      else if (open) chain=chain" "$0
      if (open && $0 !~ /\\[[:space:]]*$/ && $0 !~ /\|[[:space:]]*$/) {
        p = index(chain, "|"); r = index(chain, "redact_cmdline")
        rest = (p > 0) ? substr(chain, p + 1) : ""
        if (r == 0 || p == 0 || index(rest, "|") && index(rest, "|") < r - p) print start
        open=0
      }
    }' "$@"
}

# The guard must flag each leaking form (and accept the redacted one).
bad_forms=(
  'ps aux'
  'ps -ef'
  'ps axo pid,cmd'
  'ps -eo pid,rss,cmd'
  'pgrep -af Runner.Listener'
  'pstree -a'
  'systemctl status actions.runner.x'
  'cat /proc/1/environ'
  'cat /proc/1/cmdline'
  'ps -eo pid,cmd | cut -c1-60 | bash scripts/redact_cmdline.sh'
)
for form in "${bad_forms[@]}"; do
  printf '      run: |\n        %s\n' "$form" > "$TMP/inject.yml"
  [ -n "$(scan "$TMP/inject.yml")" ] || fail "guard missed: $form"
done
printf '        ps -eo pid,cmd \\\n          | bash scripts/redact_cmdline.sh \\\n          | cut -c1-60\n' > "$TMP/ok.yml"
[ -z "$(scan "$TMP/ok.yml")" ] || fail "guard flagged a correctly redacted pipeline"

mapfile -t files < <(find "$ROOT/.github" "$ROOT/ci" "$ROOT/scripts" -type f \
  \( -name '*.yml' -o -name '*.yaml' -o -name '*.sh' -o -name '*.py' \) \
  ! -name redact_cmdline.sh)
bad=$(scan "${files[@]}")
[ -z "$bad" ] || fail "prints full cmdline/env without scripts/redact_cmdline.sh first: $bad"

echo "OK: redact_cmdline"
