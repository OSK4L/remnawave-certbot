#!/usr/bin/env bash
set -Eeuo pipefail

# remnawave-certbot
# Universal Certbot + Cloudflare DNS-01 setup for Remnawave nodes.
# Ubuntu / Debian oriented, Docker Compose aware.

SCRIPT_VERSION="2.0.0"
PROG=${0##*/}

# ---- Defaults ----------------------------------------------------------------
DEFAULT_ZONE=${DEFAULT_ZONE:-argent-projects.com}
DEFAULT_COMPOSE_DIR=${DEFAULT_COMPOSE_DIR:-/opt/remnanode}
DEFAULT_NGINX_CONTAINER=${DEFAULT_NGINX_CONTAINER:-remnawave-nginx}
DEFAULT_CF_CREDS=${DEFAULT_CF_CREDS:-/root/.secrets/certbot/cloudflare.ini}
RENEW_WITHIN_DAYS=${RENEW_WITHIN_DAYS:-30}
PROPAGATION_SECONDS=${PROPAGATION_SECONDS:-60}
RETRY_PROPAGATION_SECONDS=${RETRY_PROPAGATION_SECONDS:-120}
HOOK_PATH=${HOOK_PATH:-/etc/letsencrypt/renewal-hooks/deploy/reload-remnawave-nginx.sh}
LOG_DIR=${LOG_DIR:-/var/log/remnawave-certbot}

MODE="apply"
ASSUME_YES=0
AUTO_CLEANUP_LEGACY=0
SKIP_DRY_RUN=0
NODE_OVERRIDE=""
ZONE_OVERRIDE=""
CF_CREDS_OVERRIDE=""
COMPOSE_DIR_OVERRIDE=""
NGINX_CONTAINER_OVERRIDE=""
NGINX_SERVICE_OVERRIDE=""

NODE_NUM=""
ZONE=""
TARGET1=""
TARGET2=""
LEGACY_NAME=""
CF_CREDS=""
COMPOSE_DIR=""
NGINX_CONTAINER=""
NGINX_SERVICE=""
HOOK_MODE=""
DOCKER_BIN=""
LOG_FILE=""
ACTIVE_PID=""
CURRENT_TASK=""

RELEVANT=()
SUMMARY_OK=()
SUMMARY_WARN=()
SUMMARY_FAIL=()
declare -A FALLBACK_ISSUED=()

# ---- UI ----------------------------------------------------------------------
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  BLUE=$'\033[34m'; CYAN=$'\033[36m'; GRAY=$'\033[90m'
else
  RESET='' BOLD='' DIM='' RED='' GREEN='' YELLOW='' BLUE='' CYAN='' GRAY=''
fi

ui_line() { printf '%b\n' "$*"; }

banner() {
  ui_line "${CYAN}${BOLD}┌──────────────────────────────────────────────────────────────┐${RESET}"
  ui_line "${CYAN}${BOLD}│  Remnawave Certbot · Cloudflare DNS-01                      │${RESET}"
  printf '%b│%b  %-58s%b│%b\n' "$CYAN$BOLD" "$RESET" "universal node setup · v${SCRIPT_VERSION}" "$CYAN$BOLD" "$RESET"
  ui_line "${CYAN}${BOLD}└──────────────────────────────────────────────────────────────┘${RESET}"
}

section() {
  printf '\n%b%s%b\n' "$BOLD$BLUE" "$1" "$RESET"
  printf '%b%s%b\n' "$GRAY" "──────────────────────────────────────────────────────────────" "$RESET"
}

ok()   { printf '%b✔%b %s\n' "$GREEN$BOLD" "$RESET" "$*"; }
info() { printf '%b●%b %s\n' "$BLUE$BOLD" "$RESET" "$*"; }
warn() { printf '%b▲%b %s\n' "$YELLOW$BOLD" "$RESET" "$*" >&2; }
fail() { printf '%b✖%b %s\n' "$RED$BOLD" "$RESET" "$*" >&2; }
note() { printf '%b  %s%b\n' "$DIM" "$*" "$RESET"; }

summary_ok()   { SUMMARY_OK+=("$*"); }
summary_warn() { SUMMARY_WARN+=("$*"); }
summary_fail() { SUMMARY_FAIL+=("$*"); }

fatal() {
  fail "$*"
  summary_fail "$*"
  exit 1
}

# ---- General helpers ----------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage: $PROG [options]

Options:
  --audit                     Audit only; do not change the node
  --yes                       Accept normal non-destructive defaults
  --cleanup-legacy            Delete unused legacy node-N lineage when safe
  --skip-dry-run              Skip final Let's Encrypt staging tests
  --node N                    Override detected node number
  --zone DOMAIN               Override detected DNS zone
  --credentials PATH          Cloudflare credentials file
  --compose-dir PATH          Docker Compose directory
  --nginx-container NAME      nginx container name
  --nginx-service NAME        Docker Compose service name
  --propagation SECONDS       DNS propagation wait (default: $PROPAGATION_SECONDS)
  -h, --help                  Show this help

Examples:
  $PROG --audit
  $PROG
  $PROG --node 6 --zone argent-projects.com
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --audit) MODE="audit" ;;
      --yes|-y) ASSUME_YES=1 ;;
      --cleanup-legacy) AUTO_CLEANUP_LEGACY=1 ;;
      --skip-dry-run) SKIP_DRY_RUN=1 ;;
      --node) shift; NODE_OVERRIDE=${1:-} ;;
      --zone) shift; ZONE_OVERRIDE=${1:-} ;;
      --credentials) shift; CF_CREDS_OVERRIDE=${1:-} ;;
      --compose-dir) shift; COMPOSE_DIR_OVERRIDE=${1:-} ;;
      --nginx-container) shift; NGINX_CONTAINER_OVERRIDE=${1:-} ;;
      --nginx-service) shift; NGINX_SERVICE_OVERRIDE=${1:-} ;;
      --propagation) shift; PROPAGATION_SECONDS=${1:-} ;;
      -h|--help) usage; exit 0 ;;
      *) fatal "Unknown option: $1" ;;
    esac
    shift
  done

  [[ $PROPAGATION_SECONDS =~ ^[0-9]+$ ]] || fatal "Propagation must be an integer."
  ((PROPAGATION_SECONDS >= 10)) || fatal "Propagation must be at least 10 seconds."
  if ((RETRY_PROPAGATION_SECONDS < PROPAGATION_SECONDS)); then
    RETRY_PROPAGATION_SECONDS=$PROPAGATION_SECONDS
  fi
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fatal "Run as root (sudo -i, then run the command again)."
}

init_log() {
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  LOG_FILE="$LOG_DIR/setup-$(date '+%Y%m%d-%H%M%S').log"
  : >"$LOG_FILE"
  chmod 600 "$LOG_FILE"
  printf 'remnawave-certbot v%s\nstarted: %s\n\n' "$SCRIPT_VERSION" "$(date -Is)" >>"$LOG_FILE"
}

log_command() {
  printf '\n$' >>"$LOG_FILE"
  printf ' %q' "$@" >>"$LOG_FILE"
  printf '\n' >>"$LOG_FILE"
}

spinner_wait() {
  local pid=$1 label=$2 i=0
  local -a spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  if [[ ! -t 1 ]]; then
    if wait "$pid"; then return 0; else return $?; fi
  fi

  while kill -0 "$pid" 2>/dev/null; do
    printf '\r%b%s%b %s' "$CYAN" "${spin[i++ % ${#spin[@]}]}" "$RESET" "$label"
    sleep 0.12
  done
  printf '\r\033[K'
  if wait "$pid"; then return 0; else return $?; fi
}

run_task() {
  local label=$1; shift
  local tmp rc
  tmp=$(mktemp)
  CURRENT_TASK=$label
  log_command "$@"

  "$@" >"$tmp" 2>&1 &
  ACTIVE_PID=$!
  if spinner_wait "$ACTIVE_PID" "$label"; then rc=0; else rc=$?; fi
  ACTIVE_PID=""

  cat "$tmp" >>"$LOG_FILE"
  if ((rc == 0)); then
    ok "$label"
  else
    fail "$label"
    printf '%b%s%b\n' "$DIM" "  Last output:" "$RESET" >&2
    tail -n 18 "$tmp" | sed 's/^/    /' >&2
    note "Full log: $LOG_FILE"
  fi
  rm -f "$tmp"
  CURRENT_TASK=""
  return "$rc"
}

on_interrupt() {
  if [[ -n ${ACTIVE_PID:-} ]]; then
    kill -TERM "$ACTIVE_PID" 2>/dev/null || true
    wait "$ACTIVE_PID" 2>/dev/null || true
  fi
  printf '\n'
  warn "Aborted by user${CURRENT_TASK:+ during: $CURRENT_TASK}. Ctrl+C is not counted as a validation failure."
  exit 130
}
trap on_interrupt INT TERM

prompt_default() {
  local __var=$1 prompt=$2 def=$3 value
  if ((ASSUME_YES)); then
    printf -v "$__var" '%s' "$def"
    return
  fi
  read -r -p "$prompt [$def]: " value
  printf -v "$__var" '%s' "${value:-$def}"
}

confirm() {
  local prompt=$1 def=${2:-N} answer suffix
  if ((ASSUME_YES)); then
    [[ $def == Y ]]
    return
  fi
  [[ $def == Y ]] && suffix='[Y/n]' || suffix='[y/N]'
  read -r -p "$prompt $suffix " answer
  answer=${answer:-$def}
  [[ $answer =~ ^[Yy]$ ]]
}

# ---- Dependencies -------------------------------------------------------------
install_certbot_if_needed() {
  have certbot && return 0
  [[ $MODE == audit ]] && fatal "Certbot is not installed."
  have apt-get || fatal "Certbot is missing and apt-get is unavailable."
  run_task "Refreshing apt metadata" apt-get update || fatal "apt-get update failed."
  run_task "Installing Certbot packages" env DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-dns-cloudflare || fatal "Certbot installation failed."
}

ensure_dns_tools() {
  have dig && return 0
  if [[ $MODE == audit ]]; then
    warn "dig is not installed; DNS preflight will be limited."
    return 0
  fi
  if have apt-get; then
    run_task "Installing DNS utilities" env DEBIAN_FRONTEND=noninteractive apt-get install -y dnsutils || warn "Could not install dnsutils; continuing without dig."
  fi
}

cloudflare_plugin_available() {
  certbot plugins 2>/dev/null | grep -qE '^\* dns-cloudflare$'
}

ensure_cloudflare_plugin() {
  if cloudflare_plugin_available; then
    ok "Certbot dns-cloudflare plugin is available"
    return 0
  fi

  [[ $MODE == audit ]] && { warn "dns-cloudflare plugin is not installed."; return 1; }
  warn "Certbot dns-cloudflare plugin is missing."

  local certbot_path
  certbot_path=$(readlink -f "$(command -v certbot)" 2>/dev/null || command -v certbot)

  if [[ $certbot_path == /snap/* ]] && have snap; then
    run_task "Allowing Certbot root plugins" snap set certbot trust-plugin-with-root=ok || return 1
    if ! snap list certbot-dns-cloudflare >/dev/null 2>&1; then
      run_task "Installing certbot-dns-cloudflare snap" snap install certbot-dns-cloudflare || return 1
    fi
  elif have apt-get; then
    run_task "Installing python3-certbot-dns-cloudflare" env DEBIAN_FRONTEND=noninteractive apt-get install -y python3-certbot-dns-cloudflare || return 1
  else
    fatal "Cannot install dns-cloudflare automatically."
  fi

  cloudflare_plugin_available || fatal "dns-cloudflare is still unavailable after installation."
  ok "Certbot dns-cloudflare plugin is available"
}

# ---- Node / certificate discovery --------------------------------------------
detect_candidates_from_renewal() {
  local f base
  shopt -s nullglob
  for f in /etc/letsencrypt/renewal/n-*.conf; do
    base=${f##*/}; base=${base%.conf}
    if [[ $base =~ ^n-([0-9]+)g?\.(.+)$ ]]; then
      printf '%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
  done | sort -u
  shopt -u nullglob
}

detect_candidates_from_configs() {
  local root match
  for root in /opt/remnanode /etc/nginx; do
    [[ -d $root ]] || continue
    while IFS= read -r match; do
      [[ $match =~ ^n-([0-9]+)g?\.(.+)$ ]] || continue
      printf '%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    done < <(grep -RhoE 'n-[0-9]+g?\.[A-Za-z0-9.-]+' "$root" 2>/dev/null | sort -u)
  done | sort -u
}

detect_identity() {
  if [[ -n $NODE_OVERRIDE ]]; then
    [[ $NODE_OVERRIDE =~ ^[0-9]+$ ]] || fatal "Invalid node number: $NODE_OVERRIDE"
    NODE_NUM=$NODE_OVERRIDE
    ZONE=${ZONE_OVERRIDE:-$DEFAULT_ZONE}
    ok "Using requested node $NODE_NUM · zone $ZONE"
    return
  fi

  local -a candidates=()
  mapfile -t candidates < <(detect_candidates_from_renewal)
  if ((${#candidates[@]} == 0)); then
    mapfile -t candidates < <(detect_candidates_from_configs)
  fi

  if ((${#candidates[@]} == 1)); then
    NODE_NUM=${candidates[0]%%|*}
    ZONE=${ZONE_OVERRIDE:-${candidates[0]#*|}}
    ok "Detected node $NODE_NUM · zone $ZONE"
    return
  fi

  if ((${#candidates[@]} > 1)); then
    warn "More than one node/zone candidate was found:"
    printf '    %s\n' "${candidates[@]}"
  else
    warn "Could not auto-detect node number from Certbot/nginx configuration."
  fi

  [[ $MODE == audit ]] && fatal "Use --node N [--zone DOMAIN] for audit mode."
  read -r -p "Node number (for example 5, 6, 13): " NODE_NUM
  [[ $NODE_NUM =~ ^[0-9]+$ ]] || fatal "Invalid node number: $NODE_NUM"
  if [[ -n $ZONE_OVERRIDE ]]; then ZONE=$ZONE_OVERRIDE; else prompt_default ZONE "DNS zone" "$DEFAULT_ZONE"; fi
}

cert_domains() {
  local name=$1 cert="/etc/letsencrypt/live/$name/cert.pem"
  [[ -r $cert ]] || return 0
  openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null \
    | grep -oE 'DNS:[^,[:space:]]+' \
    | sed 's/^DNS://' || true
}

cert_end_epoch() {
  local name=$1 cert="/etc/letsencrypt/live/$name/cert.pem" raw
  [[ -r $cert ]] || return 1
  raw=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2-)
  [[ -n $raw ]] || return 1
  date -d "$raw" +%s
}

cert_status() {
  local name=$1 now end threshold
  now=$(date +%s)
  if ! end=$(cert_end_epoch "$name"); then printf 'BROKEN'; return; fi
  threshold=$((now + RENEW_WITHIN_DAYS * 86400))
  if ((end <= now)); then
    printf 'EXPIRED'
  elif ((end <= threshold)); then
    printf 'EXPIRING'
  else
    printf 'VALID'
  fi
}

cert_expiry_date() {
  local name=$1 cert="/etc/letsencrypt/live/$name/cert.pem" raw
  [[ -r $cert ]] || { printf '-'; return; }
  raw=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2-)
  date -d "$raw" '+%Y-%m-%d' 2>/dev/null || printf '-'
}

renewal_value() {
  local name=$1 key=$2 conf="/etc/letsencrypt/renewal/$name.conf"
  [[ -r $conf ]] || return 0
  awk -F' = ' -v k="$key" '$1 == k {print $2; exit}' "$conf"
}

cert_authenticator() { renewal_value "$1" authenticator; }

is_relevant_lineage() {
  local name=$1 d
  [[ $name == "$TARGET1" || $name == "$TARGET2" ]] && return 0
  while IFS= read -r d; do
    [[ $d == "$TARGET1" || $d == "$TARGET2" ]] && return 0
  done < <(cert_domains "$name")
  return 1
}

add_relevant_once() {
  local candidate=$1 x
  for x in "${RELEVANT[@]:-}"; do [[ $x == "$candidate" ]] && return; done
  RELEVANT+=("$candidate")
}

status_badge() {
  case "$1" in
    VALID) printf '%bVALID%b' "$GREEN" "$RESET" ;;
    EXPIRING) printf '%b≤%sd%b' "$YELLOW" "$RENEW_WITHIN_DAYS" "$RESET" ;;
    EXPIRED|BROKEN) printf '%b%s%b' "$RED" "$1" "$RESET" ;;
    *) printf '%s' "$1" ;;
  esac
}

scan_certificates() {
  local f name status expiry auth domains marker
  RELEVANT=()
  LEGACY_NAME="node-${NODE_NUM}.${ZONE}"

  printf '%-39s %-10s %-18s %-12s %s\n' "CERTIFICATE" "STATUS" "AUTHENTICATOR" "EXPIRES" "DOMAINS"
  printf '%s\n' "────────────────────────────────────────────────────────────────────────────────────────────────────────"

  shopt -s nullglob
  for f in /etc/letsencrypt/renewal/*.conf; do
    name=${f##*/}; name=${name%.conf}
    status=$(cert_status "$name")
    expiry=$(cert_expiry_date "$name")
    auth=$(cert_authenticator "$name")
    domains=$(cert_domains "$name" | paste -sd, -)
    marker=''

    if [[ $name == "$LEGACY_NAME" ]]; then
      marker='  [legacy ignored]'
    elif is_relevant_lineage "$name"; then
      add_relevant_once "$name"
    fi

    printf '%-39s %-20b %-18s %-12s %s%s\n' "$name" "$(status_badge "$status")" "${auth:--}" "$expiry" "${domains:--}" "$marker"
  done
  shopt -u nullglob

  if ((${#RELEVANT[@]})); then
    ok "Relevant lineage(s): ${RELEVANT[*]}"
  else
    warn "No existing lineage covers $TARGET1 or $TARGET2."
  fi

  if [[ -f /etc/letsencrypt/renewal/$LEGACY_NAME.conf ]]; then
    warn "$LEGACY_NAME is legacy and excluded from migration and dry-runs."
    summary_warn "Legacy Certbot lineage exists: $LEGACY_NAME"
  fi
}

# ---- DNS / credentials --------------------------------------------------------
check_dns() {
  have dig || { warn "dig unavailable; DNS preflight skipped."; summary_warn "DNS preflight skipped (dig missing)"; return 0; }

  local ns a1 a2 aaaa1 aaaa2
  ns=$(dig NS "$ZONE" +short 2>/dev/null || true)
  if grep -Eqi '\.ns\.cloudflare\.com\.?$' <<<"$ns"; then
    ok "$ZONE is delegated to Cloudflare"
    summary_ok "Cloudflare authoritative DNS confirmed"
  else
    warn "Could not confirm Cloudflare nameservers for $ZONE."
    [[ -n $ns ]] && printf '%s\n' "$ns" | sed 's/^/    /'
    summary_warn "Cloudflare authoritative DNS not confirmed"
    [[ $MODE == audit ]] && return 0
    confirm "Continue despite DNS warning?" N || exit 1
  fi

  a1=$(dig +short "$TARGET1" A | paste -sd, -)
  a2=$(dig +short "$TARGET2" A | paste -sd, -)
  aaaa1=$(dig +short "$TARGET1" AAAA | paste -sd, -)
  aaaa2=$(dig +short "$TARGET2" AAAA | paste -sd, -)

  printf '    %-36s A=%-20s AAAA=%s\n' "$TARGET1" "${a1:--}" "${aaaa1:--}"
  printf '    %-36s A=%-20s AAAA=%s\n' "$TARGET2" "${a2:--}" "${aaaa2:--}"

  [[ -n $a1 || -n $aaaa1 ]] || { warn "$TARGET1 has no A/AAAA record."; summary_warn "$TARGET1 has no A/AAAA"; }
  [[ -n $a2 || -n $aaaa2 ]] || { warn "$TARGET2 has no A/AAAA record."; summary_warn "$TARGET2 has no A/AAAA"; }
}

credentials_valid_format() {
  local file=$1
  [[ -s $file ]] && grep -qE '^[[:space:]]*dns_cloudflare_api_token[[:space:]]*=' "$file"
}

get_cloudflare_credentials() {
  CF_CREDS=${CF_CREDS_OVERRIDE:-$DEFAULT_CF_CREDS}
  [[ -n $CF_CREDS_OVERRIDE ]] || prompt_default CF_CREDS "Cloudflare credentials file" "$DEFAULT_CF_CREDS"

  if credentials_valid_format "$CF_CREDS"; then
    if confirm "Reuse existing Cloudflare credentials at $CF_CREDS?" Y; then
      chmod 600 "$CF_CREDS"
      [[ -d ${CF_CREDS%/*} ]] && chmod 700 "${CF_CREDS%/*}" || true
      ok "Using existing Cloudflare credentials"
      return 0
    fi
  elif [[ -e $CF_CREDS ]]; then
    warn "$CF_CREDS exists but does not contain dns_cloudflare_api_token. It will not be reused."
  fi

  local token token2 dir
  dir=${CF_CREDS%/*}
  mkdir -p "$dir"
  chmod 700 "$dir"

  while :; do
    read -r -s -p "Cloudflare API Token (DNS Edit for $ZONE): " token
    printf '\n'
    [[ -n $token ]] || { warn "Token cannot be empty."; continue; }
    read -r -s -p "Repeat API Token: " token2
    printf '\n'
    [[ $token == "$token2" ]] || { warn "Tokens do not match."; token=''; token2=''; continue; }
    break
  done

  umask 077
  printf 'dns_cloudflare_api_token = %s\n' "$token" >"$CF_CREDS"
  chmod 600 "$CF_CREDS"
  token=''; token2=''; unset token token2
  ok "Cloudflare credentials saved with mode 0600"
}

# ---- Docker / nginx -----------------------------------------------------------
detect_docker_context() {
  DOCKER_BIN=$(command -v docker)

  NGINX_CONTAINER=${NGINX_CONTAINER_OVERRIDE:-$DEFAULT_NGINX_CONTAINER}
  if [[ -z $NGINX_CONTAINER_OVERRIDE ]] && ! docker inspect "$NGINX_CONTAINER" >/dev/null 2>&1; then
    local first
    first=$(docker ps --format '{{.Names}}' | grep -Ei 'nginx' | head -n1 || true)
    [[ -n $first ]] && NGINX_CONTAINER=$first
  fi

  [[ -n $NGINX_CONTAINER_OVERRIDE ]] || prompt_default NGINX_CONTAINER "nginx container" "$NGINX_CONTAINER"
  docker inspect "$NGINX_CONTAINER" >/dev/null 2>&1 || fatal "Container $NGINX_CONTAINER was not found."

  local wd service mounts has_full=0 has_individual=0
  wd=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$NGINX_CONTAINER" 2>/dev/null || true)
  service=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$NGINX_CONTAINER" 2>/dev/null || true)
  [[ -n $wd && $wd != '<no value>' ]] || wd=$DEFAULT_COMPOSE_DIR
  [[ -n $service && $service != '<no value>' ]] || service=$NGINX_CONTAINER

  COMPOSE_DIR=${COMPOSE_DIR_OVERRIDE:-$wd}
  NGINX_SERVICE=${NGINX_SERVICE_OVERRIDE:-$service}
  [[ -n $COMPOSE_DIR_OVERRIDE ]] || prompt_default COMPOSE_DIR "Docker Compose directory" "$COMPOSE_DIR"
  [[ -n $NGINX_SERVICE_OVERRIDE ]] || prompt_default NGINX_SERVICE "Docker Compose nginx service" "$NGINX_SERVICE"

  [[ -d $COMPOSE_DIR ]] || fatal "Compose directory does not exist: $COMPOSE_DIR"
  if ! (cd "$COMPOSE_DIR" && docker compose config >/dev/null 2>&1); then
    fatal "docker compose config failed in $COMPOSE_DIR"
  fi

  mounts=$(docker inspect "$NGINX_CONTAINER" --format '{{range .Mounts}}{{printf "%s|%s\n" .Source .Destination}}{{end}}')

  while IFS='|' read -r src dst; do
    [[ -n $src || -n $dst ]] || continue
    [[ $dst == /etc/letsencrypt || $src == /etc/letsencrypt ]] && has_full=1
    if [[ $src == /etc/letsencrypt/live/* || $src == /etc/letsencrypt/archive/* || $dst == */fullchain.pem || $dst == */privkey.pem ]]; then
      has_individual=1
    fi
  done <<<"$mounts"

  # Individual file mounts take precedence. Certbot's live files are symlinks,
  # so a Compose recreate is the safest way to resolve a new archive target.
  if ((has_individual)); then
    HOOK_MODE="recreate"
    ok "Docker certificate mode: individual file bind → recreate nginx after renewal"
  elif ((has_full)); then
    HOOK_MODE="reload"
    ok "Docker certificate mode: /etc/letsencrypt directory bind → reload nginx after renewal"
  else
    warn "No Certbot-related nginx bind mount could be identified."
    printf '%s\n' "$mounts" | sed 's/^/    /'
    if confirm "Use Compose recreate hook as the safer fallback?" Y; then
      HOOK_MODE="recreate"
    else
      HOOK_MODE="reload"
    fi
  fi

  if ! run_task "Validating current nginx configuration" docker exec "$NGINX_CONTAINER" nginx -t; then
    fatal "nginx is already invalid; refusing to change renewal automation."
  fi
}

backup_existing_hook() {
  [[ -f $HOOK_PATH ]] || return 0
  cp -a "$HOOK_PATH" "$HOOK_PATH.bak-$(date '+%Y%m%d-%H%M%S')"
}

install_deploy_hook() {
  mkdir -p "${HOOK_PATH%/*}"
  backup_existing_hook

  if [[ $HOOK_MODE == reload ]]; then
    cat >"$HOOK_PATH" <<EOF
#!/bin/sh
set -eu
CONTAINER='$NGINX_CONTAINER'
DOCKER='$DOCKER_BIN'
TARGET1='$TARGET1'
TARGET2='$TARGET2'

case " \${RENEWED_DOMAINS:-} " in
  *" \$TARGET1 "*|*" \$TARGET2 "*) ;;
  *) exit 0 ;;
esac

run_quiet() {
  if ! out="\$("\$@" 2>&1)"; then
    printf '%s\n' "\$out" >&2
    return 1
  fi
}

run_quiet "\$DOCKER" inspect "\$CONTAINER"
run_quiet "\$DOCKER" exec "\$CONTAINER" nginx -t
run_quiet "\$DOCKER" exec "\$CONTAINER" nginx -s reload
EOF
  else
    cat >"$HOOK_PATH" <<EOF
#!/bin/sh
set -eu
COMPOSE_DIR='$COMPOSE_DIR'
SERVICE='$NGINX_SERVICE'
CONTAINER='$NGINX_CONTAINER'
DOCKER='$DOCKER_BIN'
TARGET1='$TARGET1'
TARGET2='$TARGET2'

case " \${RENEWED_DOMAINS:-} " in
  *" \$TARGET1 "*|*" \$TARGET2 "*) ;;
  *) exit 0 ;;
esac

run_quiet() {
  if ! out="\$("\$@" 2>&1)"; then
    printf '%s\n' "\$out" >&2
    return 1
  fi
}

cd "\$COMPOSE_DIR"
run_quiet "\$DOCKER" compose up -d --force-recreate --no-deps "\$SERVICE"

i=0
while [ "\$i" -lt 30 ]; do
  if "\$DOCKER" inspect -f '{{.State.Running}}' "\$CONTAINER" 2>/dev/null | grep -q '^true$'; then
    if "\$DOCKER" exec "\$CONTAINER" nginx -t >/dev/null 2>&1; then
      exit 0
    fi
  fi
  i=\$((i + 1))
  sleep 1
done

printf '%s\n' "nginx did not become ready after Compose recreate" >&2
"\$DOCKER" logs --tail 50 "\$CONTAINER" >&2 || true
exit 1
EOF
  fi

  chmod 700 "$HOOK_PATH"
  if sh -n "$HOOK_PATH"; then
    ok "Deploy hook installed: $HOOK_PATH ($HOOK_MODE mode)"
    summary_ok "nginx deploy hook ($HOOK_MODE mode)"
  else
    fatal "Generated deploy hook failed shell syntax validation."
  fi
}

# ---- Certbot migration / renewal ---------------------------------------------
certbot_has_reconfigure() {
  certbot --help all 2>/dev/null | grep -qE '^[[:space:]]*reconfigure[[:space:]]'
}

lineage_is_cloudflare_ready() {
  local name=$1 auth creds prop
  auth=$(renewal_value "$name" authenticator)
  creds=$(renewal_value "$name" dns_cloudflare_credentials)
  prop=$(renewal_value "$name" dns_cloudflare_propagation_seconds)
  [[ $auth == dns-cloudflare && $creds == "$CF_CREDS" && $prop =~ ^[0-9]+$ && $prop -ge $PROPAGATION_SECONDS ]]
}

certbot_reconfigure_once() {
  local name=$1 prop=$2
  certbot reconfigure \
    --non-interactive \
    --cert-name "$name" \
    --dns-cloudflare \
    --dns-cloudflare-credentials "$CF_CREDS" \
    --dns-cloudflare-propagation-seconds "$prop"
}

fallback_certonly_existing() {
  local name=$1 prop=$2 d
  local -a args=(
    certbot certonly --non-interactive --force-renewal
    --dns-cloudflare
    --dns-cloudflare-credentials "$CF_CREDS"
    --dns-cloudflare-propagation-seconds "$prop"
    --cert-name "$name"
  )
  local count=0
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    args+=(-d "$d")
    ((count+=1))
  done < <(cert_domains "$name")
  ((count > 0)) || return 2
  "${args[@]}"
}

migrate_lineage() {
  local name=$1

  if lineage_is_cloudflare_ready "$name"; then
    ok "$name already uses Cloudflare DNS-01 (${PROPAGATION_SECONDS}s+)"
    summary_ok "$name renewal configuration"
    return 0
  fi

  info "Migrating $name to Cloudflare DNS-01"

  if certbot_has_reconfigure; then
    if run_task "$name · staging reconfigure (${PROPAGATION_SECONDS}s)" certbot_reconfigure_once "$name" "$PROPAGATION_SECONDS"; then
      summary_ok "$name migrated to Cloudflare DNS-01"
      return 0
    fi

    warn "First staging validation failed. Retrying with ${RETRY_PROPAGATION_SECONDS}s propagation."
    if run_task "$name · staging retry (${RETRY_PROPAGATION_SECONDS}s)" certbot_reconfigure_once "$name" "$RETRY_PROPAGATION_SECONDS"; then
      summary_ok "$name migrated to Cloudflare DNS-01 (${RETRY_PROPAGATION_SECONDS}s propagation)"
      return 0
    fi
  fi

  warn "Staging reconfigure did not succeed for $name."
  warn "Using production certonly fallback while preserving every SAN. This may issue a fresh certificate."
  if run_task "$name · production migration fallback" fallback_certonly_existing "$name" "$RETRY_PROPAGATION_SECONDS"; then
    FALLBACK_ISSUED["$name"]=1
    summary_warn "$name required production fallback during migration"
    return 0
  fi

  fatal "Could not migrate $name to Cloudflare DNS-01."
}

has_certbot_account() {
  [[ -d /etc/letsencrypt/accounts ]] && find /etc/letsencrypt/accounts -type f -name regr.json -print -quit 2>/dev/null | grep -q .
}

create_combined_certificate_cmd() {
  local email=$1
  local -a args=(
    certbot certonly --non-interactive
    --dns-cloudflare
    --dns-cloudflare-credentials "$CF_CREDS"
    --dns-cloudflare-propagation-seconds "$PROPAGATION_SECONDS"
    --cert-name "$TARGET1"
    -d "$TARGET1" -d "$TARGET2"
  )
  if [[ -n $email ]]; then
    args+=(--email "$email" --agree-tos --no-eff-email)
  fi
  "${args[@]}"
}

create_combined_certificate() {
  local email=''
  warn "No relevant Certbot lineage exists. A combined certificate will be created for:"
  printf '    • %s\n    • %s\n' "$TARGET1" "$TARGET2"
  confirm "Create the combined certificate?" Y || fatal "No certificate selected for migration."

  if ! has_certbot_account; then
    read -r -p "Email for Let's Encrypt account: " email
    [[ $email == *@*.* ]] || fatal "A valid email is required for the first Let's Encrypt registration."
  fi

  run_task "Issuing initial combined certificate" create_combined_certificate_cmd "$email" || fatal "Initial certificate issuance failed."
  RELEVANT=("$TARGET1")
  FALLBACK_ISSUED["$TARGET1"]=1
  summary_ok "Initial combined certificate issued"
}

renew_due_lineages() {
  local name status
  for name in "${RELEVANT[@]}"; do
    if [[ ${FALLBACK_ISSUED[$name]:-0} == 1 ]]; then
      info "$name was freshly issued during migration; production renewal skipped"
      continue
    fi

    status=$(cert_status "$name")
    case "$status" in
      EXPIRED|EXPIRING)
        if run_task "$name · production renewal" certbot renew --non-interactive --cert-name "$name" --force-renewal; then
          summary_ok "$name fresh production certificate"
        else
          fatal "Production renewal failed for $name."
        fi
        ;;
      VALID)
        ok "$name does not need a production renewal now"
        ;;
      *) fatal "$name certificate state is $status." ;;
    esac
  done
}

enable_renew_timer() {
  if systemctl list-unit-files 2>/dev/null | grep -qE '^certbot\.timer'; then
    run_task "Enabling certbot.timer" systemctl enable --now certbot.timer || fatal "Could not enable certbot.timer."
    summary_ok "certbot.timer enabled"
  elif systemctl list-unit-files 2>/dev/null | grep -qE '^snap\.certbot\.renew\.timer'; then
    run_task "Enabling snap Certbot renewal timer" systemctl enable --now snap.certbot.renew.timer || fatal "Could not enable snap Certbot timer."
    summary_ok "snap Certbot renewal timer enabled"
  else
    warn "No known Certbot systemd timer was found."
    summary_warn "Certbot renewal timer not found"
  fi
}

dry_run_relevant() {
  ((SKIP_DRY_RUN)) && { warn "Final dry-run skipped by request."; summary_warn "Dry-run skipped"; return 0; }

  local name failures=0
  for name in "${RELEVANT[@]}"; do
    if run_task "$name · staging renewal + deploy hook" certbot renew --non-interactive --cert-name "$name" --dry-run --run-deploy-hooks; then
      summary_ok "$name dry-run"
    else
      ((failures+=1))
      summary_fail "$name dry-run"
    fi
  done

  ((failures == 0)) || fatal "$failures dry-run(s) failed. See $LOG_FILE"
}

# ---- Cleanup / reporting ------------------------------------------------------
legacy_reference_report() {
  local legacy=$1 refs='' c m

  for c in "$COMPOSE_DIR" /etc/nginx; do
    [[ -d $c ]] || continue
    m=$(grep -R -n -F "$legacy" "$c" 2>/dev/null || true)
    [[ -n $m ]] && refs+="$m"$'\n'
  done

  while IFS= read -r c; do
    [[ -n $c ]] || continue
    m=$(docker inspect "$c" --format '{{range .Mounts}}{{printf "%s -> %s\n" .Source .Destination}}{{end}}' 2>/dev/null | grep -F "$legacy" || true)
    [[ -n $m ]] && refs+="container=$c: $m"$'\n'
  done < <(docker ps -a --format '{{.Names}}')

  printf '%s' "$refs"
}

maybe_cleanup_legacy() {
  local legacy=$LEGACY_NAME refs status
  [[ -f /etc/letsencrypt/renewal/$legacy.conf ]] || return 0

  status=$(cert_status "$legacy")
  warn "Legacy Certbot lineage remains: $legacy ($status)"
  refs=$(legacy_reference_report "$legacy")

  if [[ -n $refs ]]; then
    warn "It is referenced by local configuration; it will NOT be deleted:"
    printf '%s' "$refs" | sed 's/^/    /'
    summary_warn "Legacy $legacy kept because references were found"
    return 0
  fi

  note "No reference to $legacy was found in $COMPOSE_DIR, /etc/nginx, or Docker mounts."
  note "Keeping it means the global Certbot timer can still attempt to renew it."

  if ((AUTO_CLEANUP_LEGACY)); then
    :
  elif ! confirm "Delete unused legacy lineage $legacy from Certbot?" N; then
    summary_warn "Unused legacy lineage kept: $legacy"
    return 0
  fi

  if run_task "Deleting unused legacy lineage $legacy" certbot delete --non-interactive --cert-name "$legacy"; then
    summary_ok "Unused legacy lineage removed"
  else
    summary_warn "Could not delete legacy lineage $legacy"
  fi
}

redundant_lineage_notes() {
  local a b a_domains b_domains d subset
  ((${#RELEVANT[@]} >= 2)) || return 0

  for a in "${RELEVANT[@]}"; do
    a_domains=$(cert_domains "$a" | sort -u)
    [[ -n $a_domains ]] || continue
    for b in "${RELEVANT[@]}"; do
      [[ $a == "$b" ]] && continue
      b_domains=$(cert_domains "$b" | sort -u)
      [[ -n $b_domains ]] || continue
      subset=1
      while IFS= read -r d; do
        grep -Fxq "$d" <<<"$b_domains" || { subset=0; break; }
      done <<<"$a_domains"
      if ((subset)); then
        warn "$a is fully covered by the SANs of $b. It may be redundant, but it is not auto-deleted."
        summary_warn "Potential duplicate lineage: $a (covered by $b)"
        return 0
      fi
    done
  done
}

external_tls_check() {
  local d out
  have timeout || return 0
  for d in "$TARGET1" "$TARGET2"; do
    out=$(timeout 8 openssl s_client -connect "$d:443" -servername "$d" </dev/null 2>/dev/null \
      | openssl x509 -noout -enddate -subject 2>/dev/null || true)
    if [[ -n $out ]]; then
      ok "External TLS responds for $d"
      printf '%s\n' "$out" | sed 's/^/    /'
    else
      warn "Could not verify external TLS for $d:443 (service may intentionally not listen there)."
    fi
  done
}

print_timer_state() {
  if systemctl is-active --quiet certbot.timer 2>/dev/null; then
    local next
    next=$(systemctl list-timers --all --no-legend 2>/dev/null | awk '/certbot\.timer/ {$1=$1; print; exit}')
    ok "certbot.timer is active"
    [[ -n $next ]] && note "$next"
  elif systemctl is-active --quiet snap.certbot.renew.timer 2>/dev/null; then
    ok "snap.certbot.renew.timer is active"
  else
    warn "Certbot renewal timer is not active."
  fi
}

final_report() {
  section "Final verification"

  local name auth prop expiry status
  for name in "${RELEVANT[@]}"; do
    auth=$(renewal_value "$name" authenticator)
    prop=$(renewal_value "$name" dns_cloudflare_propagation_seconds)
    expiry=$(cert_expiry_date "$name")
    status=$(cert_status "$name")
    if [[ $auth == dns-cloudflare && $status == VALID ]]; then
      ok "$name · VALID until $expiry · dns-cloudflare · ${prop:-?}s"
    else
      fail "$name · $status · authenticator=${auth:-?}"
      summary_fail "$name final state"
    fi
  done

  if docker inspect "$NGINX_CONTAINER" >/dev/null 2>&1 && docker exec "$NGINX_CONTAINER" nginx -t >/dev/null 2>&1; then
    ok "$NGINX_CONTAINER is running with a valid nginx configuration"
  else
    fail "$NGINX_CONTAINER nginx validation failed"
    summary_fail "nginx validation"
  fi

  print_timer_state
  external_tls_check

  section "Result"
  printf '%bPASS%b  %d\n' "$GREEN$BOLD" "$RESET" "${#SUMMARY_OK[@]}"
  for name in "${SUMMARY_OK[@]:-}"; do [[ -n $name ]] && printf '  %b✔%b %s\n' "$GREEN" "$RESET" "$name"; done

  if ((${#SUMMARY_WARN[@]})); then
    printf '\n%bWARN%b  %d\n' "$YELLOW$BOLD" "$RESET" "${#SUMMARY_WARN[@]}"
    for name in "${SUMMARY_WARN[@]}"; do printf '  %b▲%b %s\n' "$YELLOW" "$RESET" "$name"; done
  fi

  if ((${#SUMMARY_FAIL[@]})); then
    printf '\n%bFAIL%b  %d\n' "$RED$BOLD" "$RESET" "${#SUMMARY_FAIL[@]}"
    for name in "${SUMMARY_FAIL[@]}"; do printf '  %b✖%b %s\n' "$RED" "$RESET" "$name"; done
  fi

  printf '\n'
  note "Detailed log: $LOG_FILE"
  if ((${#SUMMARY_FAIL[@]} == 0)); then
    ok "Node setup completed successfully"
  else
    fatal "Node setup finished with failures."
  fi
}

# ---- Main --------------------------------------------------------------------
main() {
  parse_args "$@"
  require_root
  init_log
  banner
  note "Secure log: $LOG_FILE"

  section "1 · Preflight"
  install_certbot_if_needed
  have openssl || fatal "openssl is required."
  have docker || fatal "Docker is required for nginx automation."
  ensure_dns_tools

  section "2 · Node discovery"
  detect_identity
  TARGET1="n-${NODE_NUM}.${ZONE}"
  TARGET2="n-${NODE_NUM}g.${ZONE}"
  LEGACY_NAME="node-${NODE_NUM}.${ZONE}"
  info "Target domains: $TARGET1 · $TARGET2"
  info "Renew threshold: ${RENEW_WITHIN_DAYS} days · DNS propagation: ${PROPAGATION_SECONDS}s"

  section "3 · Certificate audit"
  scan_certificates

  section "4 · DNS preflight"
  check_dns

  if [[ $MODE == audit ]]; then
    if cloudflare_plugin_available; then ok "dns-cloudflare plugin is installed"; else warn "dns-cloudflare plugin is not installed"; fi
    if systemctl is-active --quiet certbot.timer 2>/dev/null || systemctl is-active --quiet snap.certbot.renew.timer 2>/dev/null; then
      ok "Certbot automatic renewal timer is active"
    else
      warn "Certbot automatic renewal timer is not active"
    fi
    section "Audit complete"
    note "No changes were made."
    note "Run without --audit to configure this node."
    exit 0
  fi

  printf '\n'
  info "The next phase will configure Cloudflare DNS-01, nginx deployment hooks, and automatic renewal."
  note "Legacy $LEGACY_NAME is excluded from migration; optional cleanup happens only after reference checks."
  confirm "Continue?" Y || exit 0

  section "5 · Cloudflare"
  ensure_cloudflare_plugin || fatal "dns-cloudflare plugin is required."
  get_cloudflare_credentials

  section "6 · Docker / nginx"
  detect_docker_context
  install_deploy_hook

  section "7 · Certbot migration"
  if ((${#RELEVANT[@]} == 0)); then
    create_combined_certificate
  else
    local name
    for name in "${RELEVANT[@]}"; do migrate_lineage "$name"; done
  fi

  section "8 · Production certificates"
  renew_due_lineages

  section "9 · Automatic renewal"
  enable_renew_timer

  section "10 · End-to-end staging test"
  dry_run_relevant

  section "11 · Cleanup audit"
  maybe_cleanup_legacy
  redundant_lineage_notes

  final_report
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
