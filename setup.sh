#!/usr/bin/env bash
# setup.sh: one-time setup for agent-search-plugin
#
# Runs prerequisites P2-P5:
#   P2 - Install trafilatura
#   P3 - Generate ~/.pi/agent/searxng-settings.yml with a random secret key
#   P4 - Pull the SearXNG image and capture its digest
#   P5 - Create the searxng-agent container
#
# Prerequisite P1 (starting the Podman machine) must be done manually before running
# this script. The Podman machine requires the Hypervisor entitlement and cannot be
# started from within a sandboxed process.
#
# Usage:
#   ./setup.sh
#
# The script is idempotent: it skips any step that has already been completed.

set -euo pipefail

CONTAINER_NAME="${SEARXNG_CONTAINER_NAME:-searxng-agent}"
SETTINGS_FILE="${HOME}/.pi/agent/searxng-settings.yml"
IMAGE="docker.io/searxng/searxng:latest"

###############################################################################
# Helpers
###############################################################################

info()  { echo "[setup] $*"; }
ok()    { echo "[setup] OK: $*"; }
fail()  { echo "[setup] ERROR: $*" >&2; exit 1; }

check_podman() {
  if podman machine list 2>/dev/null | grep -q "Currently running"; then
    return 0
  fi
  return 1
}

###############################################################################
# P1 check - verify Podman machine is running
###############################################################################

info "Checking Podman machine..."
if ! command -v podman &>/dev/null; then
  fail "podman is not installed or not on PATH. Install Podman Desktop from https://podman-desktop.io/"
fi

if ! check_podman; then
  fail "Podman machine is not running. Run 'podman machine start' in a regular terminal first (outside any sandboxed session), then re-run this script."
fi
ok "Podman machine is running."

###############################################################################
# P2 - Install trafilatura
###############################################################################

info "Checking trafilatura..."
if command -v trafilatura &>/dev/null; then
  ok "trafilatura already installed ($(trafilatura --version 2>/dev/null || echo 'version unknown'))"
else
  info "Installing trafilatura..."
  pip install trafilatura
  command -v trafilatura &>/dev/null || fail "trafilatura install succeeded but binary not found on PATH"
  ok "trafilatura installed."
fi

###############################################################################
# P3 - Generate settings.yml
###############################################################################

info "Checking settings file at ${SETTINGS_FILE}..."
if [[ -f "${SETTINGS_FILE}" ]]; then
  ok "Settings file already exists; skipping generation."
else
  info "Generating settings file with random secret key..."
  mkdir -p "$(dirname "${SETTINGS_FILE}")"
  SECRET="$(openssl rand -hex 32)"
  cat > "${SETTINGS_FILE}" << EOF
use_default_settings: true

search:
  formats:
    - html
    - json
  safe_search: 0

server:
  limiter: false
  secret_key: "${SECRET}"

engines:
  - name: startpage
    disabled: true
  - name: google news
    disabled: true
EOF
  ok "Settings file written."
fi

###############################################################################
# P4 - Pull image and capture digest
###############################################################################

info "Pulling SearXNG image (${IMAGE})..."
podman pull "${IMAGE}"
DIGEST_REF="$(podman image inspect "${IMAGE}" --format '{{index .RepoDigests 0}}')"
if [[ -z "${DIGEST_REF}" ]]; then
  fail "Could not capture image digest. Check that the pull succeeded."
fi
ok "Image pulled. Digest ref: ${DIGEST_REF}"

###############################################################################
# P5 - Create container
###############################################################################

info "Checking for existing container '${CONTAINER_NAME}'..."
if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
  ok "Container '${CONTAINER_NAME}' already exists; skipping creation."
else
  info "Creating container '${CONTAINER_NAME}'..."
  podman create \
    --name "${CONTAINER_NAME}" \
    -p 127.0.0.1:8080:8080 \
    --user 977:977 \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --read-only \
    --tmpfs /tmp \
    --memory=512m \
    --pids-limit=256 \
    -v "${SETTINGS_FILE}:/etc/searxng/settings.yml:ro" \
    -e SEARXNG_BASE_URL=http://localhost:8080 \
    "${DIGEST_REF}"
  ok "Container '${CONTAINER_NAME}' created."
fi

###############################################################################
# Summary
###############################################################################

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo "  1. Install the extension:"
echo "     ln -sf \$(pwd)/web-search.ts ~/.pi/agent/extensions/web-search.ts"
echo ""
echo "  2. Start a pi session and verify:"
echo "     /tools   # should list web_search and fetch_url"
echo ""
echo "The container will start automatically on first use and stop after"
echo "5 minutes of inactivity."
echo ""
echo "Audit log: ~/.pi/agent/web-search-audit.log"
