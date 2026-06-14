#!/usr/bin/env bash
# Runner bootstrap — run once on the self-hosted runner to pre-install
# tooling that CI would otherwise download every run.
#
# Usage: sudo bash .github/setup-runner.sh
#
# After running, the CI workflow skips install steps when it detects
# the tools are already present.
set -euo pipefail

echo "=== Engram CI Runner Setup ==="

# Push-capable OCI distribution registry (registry:2) on :5001 — the same
# LOCAL_REGISTRY the CI workflow seeds/pulls from. NOT the rpardini
# pull-through proxy on :5000: that's a read-only MITM cache, so a
# `docker push` to it fails (and used to abort this whole bootstrap). See
# engram-infra#315.
DOCKER_REGISTRY="10.0.20.214:5001"
NPM_REGISTRY="http://10.0.20.214:4873"

# ── System dependencies for e2e tests ───────────────────────────────────
# Obsidian (Electron) needs GTK3 + a bunch of GUI libs; Xvfb + xkb files +
# xdg-utils + xmllint for sitemap test. Run as root via sudo.
if command -v apt-get &>/dev/null; then
  echo "Installing apt system dependencies (Electron/Obsidian + Xvfb + xmllint)..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    xvfb xdg-utils libxml2-utils \
    libgtk-3-0 libgbm1 libnss3 libxss1 libasound2t64 libxshmfence1 \
    libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 \
    libxrandr2 libpango-1.0-0 libcairo2 libatk1.0-0 libatk-bridge2.0-0 \
    libcups2 libnotify4 libsecret-1-0 fonts-noto-color-emoji >/dev/null
fi

# ── Docker insecure registry ─────────────────────────────────────────────
DAEMON_JSON="/etc/docker/daemon.json"
if ! grep -q "$DOCKER_REGISTRY" "$DAEMON_JSON" 2>/dev/null; then
  echo "Adding ${DOCKER_REGISTRY} as insecure registry..."
  if [ -f "$DAEMON_JSON" ]; then
    # Merge into existing config
    python3 -c "
import json
with open('$DAEMON_JSON') as f: cfg = json.load(f)
regs = cfg.setdefault('insecure-registries', [])
if '$DOCKER_REGISTRY' not in regs: regs.append('$DOCKER_REGISTRY')
with open('$DAEMON_JSON', 'w') as f: json.dump(cfg, f, indent=2)
"
  else
    echo '{"insecure-registries": ["'"$DOCKER_REGISTRY"'"]}' > "$DAEMON_JSON"
  fi
  echo "Restarting Docker daemon..."
  systemctl restart docker
else
  echo "Docker already trusts ${DOCKER_REGISTRY}"
fi

# ── Seed local Docker registry ───────────────────────────────────────────
# (Run before Python/Playwright so failures there don't block image seeding)
echo "Pushing CI images to local Docker registry (${DOCKER_REGISTRY})..."
ELIXIR_IMAGE="hexpm/elixir:1.17.3-erlang-27.1.2-debian-bookworm-20241202-slim"
RUNNER_IMAGE="debian:bookworm-20241202-slim"
for img in postgres:18.4 qdrant/qdrant:v1.17.1 node:20-slim "$ELIXIR_IMAGE" "$RUNNER_IMAGE"; do
  local_tag="${DOCKER_REGISTRY}/${img}"
  docker pull "$img"
  docker tag "$img" "$local_tag"
  docker push "$local_tag"
  echo "  ✓ ${local_tag}"
done

# ── Python packages (pytest, playwright, requests) ───────────────────────
echo "Installing Python packages..."
pip3 install --upgrade 'playwright>=1.48' pytest pytest-rerunfailures pytest-xdist pytest-timeout requests websockets

echo "Installing Playwright Chromium..."
# Install browser only — skip --with-deps (requires apt, unavailable on Fedora).
# Playwright deps (nss, atk, etc.) should be installed via dnf separately.
python3 -m playwright install chromium

echo "Configuring npm to use local Verdaccio registry..."
npm config set registry "$NPM_REGISTRY"

# ── Claude Code CLI ──────────────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
  echo "Installing Claude Code CLI..."
  npm install -g @anthropic-ai/claude-code
else
  echo "Claude Code CLI already installed: $(claude --version)"
fi

# ── Multiple runner instances ────────────────────────────────────────────
# Current topology: 7 generic, org-scoped runner agents on this host
# (runner-1 … runner-7). All advertise the same label set and drain the
# same `[self-hosted, linux, x64, isolated]` pool — any runner can pick
# up any workflow across any repo in the engram-app org. No purpose-named
# or per-repo runners.
#
# Each runner is an independent agent process with its own work directory
# (~/actions-runner-N). To add another instance, increment N and:
#
# Setup (run as open-claw, not root):
#   N=8
#   mkdir ~/actions-runner-$N && cd ~/actions-runner-$N
#   curl -o actions-runner-linux-x64.tar.gz -L \
#     https://github.com/actions/runner/releases/download/v2.323.0/actions-runner-linux-x64-2.323.0.tar.gz
#   tar xzf actions-runner-linux-x64.tar.gz
#   ./config.sh --url https://github.com/engram-app \
#     --labels isolated --name runner-$N
#   sudo ./svc.sh install && sudo ./svc.sh start
#
# `self-hosted`, `linux`, `x64` are added automatically by the runner agent;
# only `isolated` needs to be passed via --labels. Registering at the org
# URL (not a repo URL) is what lets any repo in engram-app schedule onto it.

# ── Obsidian AppImage (download + pre-extract latest) ────────────────────
# Obsidian's --appimage-extract-and-run re-extracts squashfs on every launch
# (~15-30s per boot × 3 instances = 45-90s per CI run). Pre-extracting once
# eliminates this overhead. Runs as the runner user (no sudo needed).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT="$SCRIPT_DIR/update-obsidian.sh"
if [ -x "$UPDATE_SCRIPT" ]; then
  if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    sudo -u "$SUDO_USER" -H bash "$UPDATE_SCRIPT"
  else
    bash "$UPDATE_SCRIPT"
  fi
else
  echo "WARNING: $UPDATE_SCRIPT not found — skipping Obsidian update"
fi

# ── Verify ───────────────────────────────────────────────────────────────
echo ""
echo "=== Verification ==="
echo "Python:     $(python3 --version)"
echo "Playwright: $(python3 -m playwright --version)"
echo "pytest:     $(python3 -m pytest --version)"
echo "Docker:     $(docker --version)"
echo "Claude:     $(claude --version 2>/dev/null || echo 'not found')"
echo ""
echo "Docker images:"
docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' | grep -E 'postgres|qdrant|node'
# ── Export LOCAL_REGISTRY for CI workflows ───────────────────────────────
RUNNER_ENV="/home/open-claw/actions-runner-engram/.env"
if [ -f "$RUNNER_ENV" ] && ! grep -q "LOCAL_REGISTRY" "$RUNNER_ENV"; then
  echo "LOCAL_REGISTRY=${DOCKER_REGISTRY}" >> "$RUNNER_ENV"
  echo "Added LOCAL_REGISTRY to runner .env"
elif [ -f "$RUNNER_ENV" ]; then
  echo "LOCAL_REGISTRY already in runner .env"
else
  echo "WARNING: Runner .env not found at ${RUNNER_ENV} — set LOCAL_REGISTRY manually"
fi

echo ""
echo "=== Runner setup complete ==="
