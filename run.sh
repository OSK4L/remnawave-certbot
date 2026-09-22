#!/usr/bin/env bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/OSK4L/remnawave-certbot/main"
SCRIPT_URL="$REPO_RAW/setup-node-certbot-cloudflare.sh"
INSTALL_PATH="/usr/local/sbin/remnawave-certbot"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run as root."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    apt-get update
    apt-get install -y curl
fi

tmp="$(mktemp)"

cleanup() {
    rm -f "$tmp"
}
trap cleanup EXIT

echo "[+] Downloading latest remnawave-certbot..."

curl \
    --fail \
    --silent \
    --show-error \
    --location \
    "$SCRIPT_URL" \
    --output "$tmp"

echo "[+] Checking script syntax..."

bash -n "$tmp"

echo "[+] Installing latest version..."

install \
    -o root \
    -g root \
    -m 700 \
    "$tmp" \
    "$INSTALL_PATH"

echo "[+] Starting remnawave-certbot..."

exec "$INSTALL_PATH"
