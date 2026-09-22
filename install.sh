#!/usr/bin/env bash
set -Eeuo pipefail

RAW_URL=${REMNAWAVE_CERTBOT_URL:-https://raw.githubusercontent.com/OSK4L/remnawave-certbot/main/setup-node-certbot-cloudflare.sh}
INSTALL_PATH=${REMNAWAVE_CERTBOT_INSTALL_PATH:-/usr/local/sbin/remnawave-certbot}

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf 'Run as root: sudo -i\n' >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
  else
    printf 'curl is required.\n' >&2
    exit 1
  fi
fi

tmp=$(mktemp)
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT

printf '\033[1;36m→\033[0m Downloading latest remnawave-certbot...\n'
curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location "$RAW_URL" --output "$tmp"

printf '\033[1;36m→\033[0m Validating Bash syntax...\n'
bash -n "$tmp"

printf '\033[1;36m→\033[0m Installing %s...\n' "$INSTALL_PATH"
install -o root -g root -m 700 "$tmp" "$INSTALL_PATH"

printf '\033[1;32m✔\033[0m Latest version installed. Starting setup...\n\n'
trap - EXIT
rm -f "$tmp"
exec "$INSTALL_PATH" "$@"
