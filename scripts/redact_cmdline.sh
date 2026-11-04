#!/usr/bin/env bash
# scripts/redact_cmdline.sh: stdin -> stdout filter that masks credential
# arguments in process command lines before they reach a (public) CI log.
# Self-hosted runners carry `--jitconfig <credential>` in argv; config.sh
# takes `--token <credential>`. Pipe any `ps ... cmd` / `pgrep -a` output
# through this. Guarded by test/scripts/redact_cmdline_test.sh.
exec sed -E 's/(--(jitconfig|token))([= ]+)[^ ]+/\1 [REDACTED]/g'
