#!/usr/bin/env bash
# test/scripts/redact_cmdline_test.sh
#
# The runner-diagnostics job (cron.yml) prints process command lines on
# self-hosted runners whose logs are PUBLIC. Other runners on the same host
# carry `--jitconfig <credential>` in argv, a live registration credential.
# Proves scripts/redact_cmdline.sh strips it, and that no workflow prints a
# full command line without routing it through the redactor.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REDACT="${REDACT:-$ROOT/scripts/redact_cmdline.sh}"

fail() { echo "FAIL: $*" >&2; exit 1; }

check() { # $1 = input line, $2 = secret that must not survive
  local out
  out=$(printf '%s\n' "$1" | bash "$REDACT")
  case "$out" in *"$2"*) fail "secret survived redaction: $out" ;; esac
  case "$out" in *REDACTED*) ;; *) fail "no [REDACTED] marker: $out" ;; esac
}

check '1234 Runner.Listener run --jitconfig ABC123secret' ABC123secret
check '1234 Runner.Listener run --jitconfig=ABC123secret --once' ABC123secret
check '1 a --jitconfig AAAsecret; 2 b --jitconfig BBBsecret' BBBsecret
check './config.sh --url https://x --token TOKsecret' TOKsecret

# Lines without a credential pass through untouched.
plain='42 /usr/bin/Xvfb :99 -screen 0 1280x1024x24'
[ "$(printf '%s\n' "$plain" | bash "$REDACT")" = "$plain" ] || fail "mangled a clean line"

# Structural guard: any workflow line that prints full argv (ps ... cmd/args,
# pgrep -a / --list-full, /proc/*/cmdline) must pipe through the redactor,
# on that line or a continuation of it.
bad=$(awk '
  FNR==1 { cont=0 }
  {
    hit = ($0 ~ /ps [^|]*-[a-zA-Z]*o +[^ |]*(cmd|args|command)|pgrep [^|]*(-[a-z]*a|--list-full)|\/proc\/[^ ]*\/cmdline/) && $0 !~ /^[[:space:]]*#/
    if (hit) { start=FILENAME":"FNR; chain=$0; open=1 }
    else if (open) chain=chain" "$0
    if (open && $0 !~ /\\[[:space:]]*$/ && $0 !~ /\|[[:space:]]*$/) {
      if (chain !~ /redact_cmdline/) print start
      open=0
    }
  }' "$ROOT"/.github/workflows/*.yml)
[ -z "$bad" ] || fail "workflow prints full cmdline without scripts/redact_cmdline.sh: $bad"

echo "OK: redact_cmdline"
