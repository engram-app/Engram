#!/usr/bin/env bash
# scripts/discord_release_notes.sh
#
# Turn a GitHub release body into a Discord announcement a human actually
# wants to read. Release notes on stdin, announcement on stdout.
#
# Usage:
#   discord_release_notes.sh <product> <tag> <release-url> < notes.md
#
# Why this exists: the old announce steps posted `${NOTES:0:1600}` — a raw
# prefix of the release body. For engram that body OPENS with the
# SCHEMA-IMPACT block (self-host upgrade choreography + a 28-item PR list),
# so the 1600-char window was consumed entirely by `docker compose down`
# instructions and the actual Features/Bug Fixes never reached Discord.
# Truncating a document that front-loads its least interesting section is
# how you get an announcement nobody reads.
#
# What this does instead:
#   - selects bullets by SECTION rather than by byte offset, so the
#     SCHEMA-IMPACT preamble drops out structurally (its headers aren't in
#     the include list and its items are `- `, not release-please's `* `)
#   - collapses schema impact to a single warning line
#   - strips markdown link noise, keeping the bare `(#123)` ref
#   - counts chores/docs/deps instead of listing them
#   - drops internal SCOPES even inside user-facing sections: release-please
#     groups by commit TYPE, so `fix(ci):` and `fix(deps):` land under
#     "Bug Fixes" and drown the handful of fixes a user would care about.
#     The scope, not the section, is where the user-facing signal lives.
#   - fills a 2000-char budget with WHOLE bullets, so truncation can never
#     cut mid-URL and the full-notes link is always reachable
set -euo pipefail

PRODUCT="${1:?product name required}"
TAG="${2:?tag required}"
URL="${3:?release url required}"

# Discord's hard cap on `content` is 2000 characters; a 400 here is
# invisible in CI (the caller only warns), so stay under it by construction
# rather than hoping releases stay small.
MAX=2000

notes=$(cat)

# Section header -> the label we show. Anything not listed is non-user-facing
# and gets counted, not listed. Keys are the release-please defaults.
section_label() {
  case "$1" in
    "Features")                 echo "New" ;;
    "Bug Fixes")                echo "Fixed" ;;
    "Performance Improvements") echo "Faster" ;;
    "Reverts")                  echo "Reverted" ;;
    *)                          echo "" ;;
  esac
}

# Scopes that describe work on the project rather than work a user can
# observe. A `fix(ci):` is a real fix — just not one to announce.
is_internal_scope() {
  case "$1" in
    ci|cd|deps|dep|e2e|test|tests|build|infra|chore|chores|dev|docs|doc|runner|lint|release|meta)
      return 0 ;;
    *) return 1 ;;
  esac
}

# Strip markdown noise from one bullet:
#   ([#1219](https://.../issues/1219)) -> (#1219)      keep the ref
#   ([f7415ae](https://.../commit/..)) -> (removed)    commit links are noise
#   [text](url)                        -> text         any survivor
clean_bullet() {
  sed -E \
    -e 's/\(\[#([0-9]+)\]\([^)]*\)\)/(#\1)/g' \
    -e 's/ *\(\[[0-9a-f]{6,}\]\([^)]*\)\)//g' \
    -e 's/\[([^]]*)\]\([^)]*\)/\1/g' \
    -e 's/[[:space:]]+$//'
}

# --- Parse: walk sections, bucket bullets ------------------------------
declare -A bullets      # label -> newline-joined bullets
declare -a order        # labels in first-seen order
other_count=0
current=""

while IFS= read -r line; do
  case "$line" in
    '### '*|'## '*)
      # Normalize "### Features" / "## Features" -> "Features"
      current="${line#\#\#}"
      current="${current#\#}"
      current="${current# }"
      continue
      ;;
  esac

  # release-please emits changelog entries as `* `. The SCHEMA-IMPACT block
  # uses `- `, which is why it never lands here.
  case "$line" in
    '* '*) ;;
    *) continue ;;
  esac

  label=$(section_label "$current")
  if [ -z "$label" ]; then
    other_count=$((other_count + 1))
    continue
  fi

  text=$(printf '%s' "${line#\* }" | clean_bullet)
  [ -n "$text" ] || continue

  # `**scope:** rest` — pull the scope out and drop the whole entry when it
  # names internal work. Unscoped bullets always pass.
  case "$text" in
    '**'*':**'*)
      scope="${text#\*\*}"
      scope="${scope%%:\*\**}"
      if is_internal_scope "$scope"; then
        other_count=$((other_count + 1))
        continue
      fi
      ;;
  esac

  if [ -z "${bullets[$label]+x}" ]; then
    order+=("$label")
    bullets[$label]="$text"
  else
    bullets[$label]="${bullets[$label]}"$'\n'"$text"
  fi
done <<< "$notes"

# --- Assemble: fixed parts first, then fill the remaining budget -------
head_block="**${PRODUCT} ${TAG}**"

schema_line=""
case "$notes" in
  *SCHEMA-IMPACT*) schema_line=$'\n'"⚠️ Database schema changes — back up before upgrading." ;;
esac

footer=$'\n\n'"Full notes: ${URL}"

# Reserve room for the worst-case "omitted" line so adding it later can
# never push the message over the cap.
omitted_reserve=$'\n'"…and 999 more"

body=""
omitted=0
budget=$(( MAX - ${#head_block} - ${#schema_line} - ${#footer} - ${#omitted_reserve} ))

for label in "${order[@]}"; do
  group_open=1
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if [ "$omitted" -gt 0 ]; then
      omitted=$((omitted + 1))
      continue
    fi
    chunk=""
    [ "$group_open" -eq 1 ] && chunk=$'\n\n'"**${label}**"
    chunk="${chunk}"$'\n'"• ${b}"

    if [ $(( ${#body} + ${#chunk} )) -gt "$budget" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    body="${body}${chunk}"
    group_open=0
  done <<< "${bullets[$label]}"
done

tail_lines=""
[ "$omitted" -gt 0 ] && tail_lines="${tail_lines}"$'\n'"…and ${omitted} more"
[ "$other_count" -gt 0 ] && tail_lines="${tail_lines}"$'\n'"Plus ${other_count} internal changes (chores, docs, deps)."

out="${head_block}${schema_line}${body}${tail_lines}${footer}"

# Belt and braces: if a pathological bullet still overshot, cut to the cap
# at a line boundary and re-attach the link so the reader can always escape
# to the full notes.
if [ "${#out}" -gt "$MAX" ]; then
  keep=$(( MAX - ${#footer} - 4 ))
  out="${out:0:$keep}"
  out="${out%$'\n'*}"$'\n'"…${footer}"
fi

printf '%s' "$out"
