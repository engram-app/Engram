#!/usr/bin/env bash
# scripts/redact_cmdline.sh: stdin -> stdout filter that masks credential
# arguments in process command lines before they reach a (public) CI log.
# Self-hosted runners carry `--jitconfig <credential>` in argv; config.sh
# takes `--token`/`--pat <credential>`. Any dash count, case, `=`/space/tab.
# Pipe any `ps ... cmd` / `pgrep -a` output through this as the FIRST stage.
# Guarded by test/scripts/redact_cmdline_test.sh.
exec sed -E 's/(-{1,2}(jitconfig|token|pat))([=[:space:]]+)[^[:space:]]+/\1 [REDACTED]/Ig'
