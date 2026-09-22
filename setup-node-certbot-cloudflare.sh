#!/usr/bin/env bash
set -Eeuo pipefail

# Universal Certbot + Cloudflare DNS-01 setup for Remnawave nodes.
# - Auto-detects node number/zone from existing Certbot lineages when possible.
# - Ignores legacy node-N.<zone> certificates by default.
# - Migrates n-N / n-Ng certificates to dns-cloudflare.
# - Renews expired / <=30-day certificates.
# - Installs a deploy hook for Docker nginx:
#     * reload if /etc/letsencrypt is mounted as a whole
#     * recreate the nginx Compose service if individual cert files are bind-mounted
# - Enables the Certbot timer when available.

PROG=${0##*/}
RENEW_WITHIN_DAYS=${RENEW_WITHIN_DAYS:-30}
DEFAULT_ZONE=${DEFAULT_ZONE:-argent-projects.com}
DEFAULT_COMPOSE_DIR=${DEFAULT_COMPOSE_DIR:-/opt/remnanode}
DEFAULT_NGINX_CONTAINER=${DEFAULT_NGINX_CONTAINER:-remnawave-nginx}
CF_CREDS_DEFAULT=${CF_CREDS_DEFAULT:-/root/.secrets/certbot/cloudflare.ini}
HOOK_PATH=/etc/letsencrypt/renewal-hooks/deploy/reload-remnawave-nginx.sh

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
info() { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root: sudo $PROG"
}

have() { command -v "$1" >/dev/null 2>&1; }

prompt_default() {
  local __var=$1 prompt=$2 def=$3 value
  read -r -p "$prompt [$def]: " value
  printf -v "$__var" '%s' "${value:-$def}"
}

confirm() {
  local prompt=$1 def=${2:-N} answer suffix
  if [[ $def == Y ]]; then suffix='[Y/n]'; else suffix='[y/N]'; fi
  read -r -p "$prompt $suffix " answer
  answer=${answer:-$def}
  [[ $answer =~ ^[Yy]$ ]]
}

install_certbot_if_needed() {
  if have certbot; then return; fi
  warn "Certbot is not installed. Installing apt packages..."
  have apt-get || die "Certbot missing and apt-get is unavailable. Install Certbot manually."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-dns-cloudflare
}

ensure_cloudflare_plugin() {
  if certbot plugins 2>/dev/null | grep -qE '^\* dns-cloudflare$'; then
    log "Certbot dns-cloudflare plugin is installed."
    return
  fi

  warn "dns-cloudflare plugin not found; attempting installation."
  if have snap && snap list certbot >/dev/null 2>&1; then
    snap set certbot trust-plugin-with-root=ok
    if ! snap list certbot-dns-cloudflare >/dev/null 2>&1; then
      snap install certbot-dns-cloudflare
    fi
  elif have apt-get; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3-certbot-dns-cloudflare
  else
    die "Cannot install dns-cloudflare automatically (neither snap Certbot nor apt-get detected)."
  fi

  certbot plugins 2>/dev/null | grep -qE '^\* dns-cloudflare$' || die "dns-cloudflare plugin is still unavailable."
  log "dns-cloudflare plugin installed."
}

# Echo one candidate per line as NODE|ZONE.
detect_candidates() {
  local f base
  shopt -s nullglob
  for f in /etc/letsencrypt/renewal/n-*.conf; do
    base=${f##*/}
    base=${base%.conf}
    if [[ $base =~ ^n-([0-9]+)g?\.(.+)$ ]]; then
      printf '%s|%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    fi
  done | sort -u
  shopt -u nullglob
}

detect_identity() {
  local -a candidates=()
  mapfile -t candidates < <(detect_candidates)

  if ((${#candidates[@]} == 1)); then
    NODE_NUM=${candidates[0]%%|*}
    ZONE=${candidates[0]#*|}
    log "Detected node: $NODE_NUM, zone: $ZONE"
    return
  fi

  if ((${#candidates[@]} > 1)); then
    warn "Multiple node/zone candidates found:"
    printf '  - %s\n' "${candidates[@]}"
  else
    warn "Could not auto-detect node number/zone from Certbot lineages."
  fi

  read -r -p "Node number (e.g. 5, 6, 13): " NODE_NUM
  [[ $NODE_NUM =~ ^[0-9]+$ ]] || die "Invalid node number: $NODE_NUM"
  prompt_default ZONE "DNS zone" "$DEFAULT_ZONE"
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
  if ! end=$(cert_end_epoch "$name"); then
    printf 'BROKEN'
    return
  fi
  threshold=$((now + RENEW_WITHIN_DAYS * 86400))
  if ((end <= now)); then
    printf 'EXPIRED'
  elif ((end <= threshold)); then
    printf 'EXPIRING<=%dd' "$RENEW_WITHIN_DAYS"
  else
    printf 'VALID'
  fi
}

cert_expiry_text() {
  local name=$1 cert="/etc/letsencrypt/live/$name/cert.pem"
  [[ -r $cert ]] || { printf '-'; return; }
  openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2- || printf '-'
}

cert_authenticator() {
  local name=$1 conf="/etc/letsencrypt/renewal/$name.conf"
  [[ -r $conf ]] || { printf '-'; return; }
  awk -F' = ' '/^authenticator = / {print $2; exit}' "$conf"
}

is_ignored_legacy() {
  local name=$1
  [[ $name == "node-${NODE_NUM}.${ZONE}" ]]
}

is_relevant_lineage() {
  local name=$1 d
  [[ $name == "n-${NODE_NUM}.${ZONE}" || $name == "n-${NODE_NUM}g.${ZONE}" ]] && return 0
  while IFS= read -r d; do
    [[ $d == "n-${NODE_NUM}.${ZONE}" || $d == "n-${NODE_NUM}g.${ZONE}" ]] && return 0
  done < <(cert_domains "$name")
  return 1
}

scan_certificates() {
  local f name status expiry auth domains ignored
  RELEVANT=()
  LEGACY_NAME="node-${NODE_NUM}.${ZONE}"

  printf '\n%-42s %-15s %-22s %-16s %s\n' 'CERTIFICATE' 'STATUS' 'AUTHENTICATOR' 'EXPIRES' 'DOMAINS'
  printf '%*s\n' 125 '' | tr ' ' '-'

  shopt -s nullglob
  for f in /etc/letsencrypt/renewal/*.conf; do
    name=${f##*/}; name=${name%.conf}
    status=$(cert_status "$name")
    expiry=$(cert_expiry_text "$name")
    auth=$(cert_authenticator "$name")
    domains=$(cert_domains "$name" | paste -sd, -)
    ignored=''

    if is_ignored_legacy "$name"; then
      ignored=' [IGNORED legacy node-N]'
    elif is_relevant_lineage "$name"; then
      RELEVANT+=("$name")
    fi

    # First scan shows all Certbot lineages, but explicitly marks node-N ignored.
    printf '%-42s %-15s %-22s %-16s %s%s\n' "$name" "$status" "${auth:--}" "$(date -d "$expiry" '+%F' 2>/dev/null || echo '-')" "${domains:--}" "$ignored"
  done
  shopt -u nullglob

  printf '\n'
  if ((${#RELEVANT[@]})); then
    log "Relevant lineages: ${RELEVANT[*]}"
  else
    warn "No existing relevant n-${NODE_NUM}/n-${NODE_NUM}g lineages found."
  fi

  if [[ -f /etc/letsencrypt/renewal/$LEGACY_NAME.conf ]]; then
    warn "$LEGACY_NAME is intentionally ignored by migration logic."
    warn "Note: the stock Certbot timer may still try to renew it while its renewal file exists."
  fi
}

check_dns() {
  if have dig; then
    local ns
    ns=$(dig NS "$ZONE" +short 2>/dev/null || true)
    if grep -qi 'cloudflare\.com\.?$' <<<"$ns"; then
      log "Zone $ZONE uses Cloudflare nameservers."
    else
      warn "Could not confirm Cloudflare nameservers for $ZONE."
      printf '%s\n' "$ns"
      confirm "Continue anyway?" N || exit 1
    fi
    info "A/AAAA records:"
    printf '  %-36s A=%s AAAA=%s\n' "n-${NODE_NUM}.${ZONE}" "$(dig +short "n-${NODE_NUM}.${ZONE}" A | paste -sd, -)" "$(dig +short "n-${NODE_NUM}.${ZONE}" AAAA | paste -sd, -)"
    printf '  %-36s A=%s AAAA=%s\n' "n-${NODE_NUM}g.${ZONE}" "$(dig +short "n-${NODE_NUM}g.${ZONE}" A | paste -sd, -)" "$(dig +short "n-${NODE_NUM}g.${ZONE}" AAAA | paste -sd, -)"
  else
    warn "dig not installed; skipping nameserver/A/AAAA preflight check."
  fi
}

get_cloudflare_credentials() {
  prompt_default CF_CREDS "Cloudflare credentials file" "$CF_CREDS_DEFAULT"

  if [[ -s $CF_CREDS ]]; then
    if confirm "Credentials file $CF_CREDS already exists. Reuse it?" Y; then
      chmod 600 "$CF_CREDS"
      return
    fi
  fi

  local token token2 dir
  dir=${CF_CREDS%/*}
  mkdir -p "$dir"
  chmod 700 "$dir"

  while :; do
    read -r -s -p "Cloudflare API Token (Zone:DNS:Edit for $ZONE): " token
    printf '\n'
    [[ -n $token ]] || { warn "Token cannot be empty."; continue; }
    read -r -s -p "Repeat API Token: " token2
    printf '\n'
    [[ $token == "$token2" ]] || { warn "Tokens do not match."; token=''; token2=''; continue; }
    break
  done

  umask 077
  printf 'dns_cloudflare_api_token = %s\n' "$token" > "$CF_CREDS"
  chmod 600 "$CF_CREDS"
  token=''; token2=''
  unset token token2
  log "Cloudflare credentials saved to $CF_CREDS (0600)."
}

detect_docker_context() {
  NGINX_CONTAINER=$DEFAULT_NGINX_CONTAINER
  if ! docker inspect "$NGINX_CONTAINER" >/dev/null 2>&1; then
    local first
    first=$(docker ps --format '{{.Names}}' | grep -E 'nginx' | head -n1 || true)
    [[ -n $first ]] && NGINX_CONTAINER=$first
  fi

  prompt_default NGINX_CONTAINER "Nginx container name" "$NGINX_CONTAINER"
  docker inspect "$NGINX_CONTAINER" >/dev/null 2>&1 || die "Container $NGINX_CONTAINER not found."

  local wd service
  wd=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$NGINX_CONTAINER" 2>/dev/null || true)
  service=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$NGINX_CONTAINER" 2>/dev/null || true)
  [[ -n $wd && $wd != '<no value>' ]] || wd=$DEFAULT_COMPOSE_DIR
  [[ -n $service && $service != '<no value>' ]] || service=$NGINX_CONTAINER

  prompt_default COMPOSE_DIR "Docker Compose directory" "$wd"
  prompt_default NGINX_SERVICE "Docker Compose nginx service" "$service"

  [[ -d $COMPOSE_DIR ]] || die "Compose directory does not exist: $COMPOSE_DIR"
  (cd "$COMPOSE_DIR" && docker compose config >/dev/null) || die "docker compose config failed in $COMPOSE_DIR"

  local mounts
  mounts=$(docker inspect "$NGINX_CONTAINER" --format '{{range .Mounts}}{{println .Source "|" .Destination}}{{end}}')

  if grep -qE '^/etc/letsencrypt \| ' <<<"$mounts"; then
    HOOK_MODE=reload
    log "Docker mode: full /etc/letsencrypt bind detected -> nginx reload after renewal."
  elif grep -qE '^/etc/letsencrypt/live/' <<<"$mounts"; then
    HOOK_MODE=recreate
    log "Docker mode: individual Certbot file bind(s) detected -> recreate nginx after renewal."
  else
    warn "Could not detect how nginx receives Certbot certificates."
    printf '%s\n' "$mounts"
    if confirm "Use safe Compose recreate hook?" Y; then HOOK_MODE=recreate; else HOOK_MODE=reload; fi
  fi
}

install_deploy_hook() {
  mkdir -p "${HOOK_PATH%/*}"

  if [[ $HOOK_MODE == reload ]]; then
    cat >"$HOOK_PATH" <<EOF
#!/bin/sh
set -eu
CONTAINER='$NGINX_CONTAINER'
case " \${RENEWED_DOMAINS:-} " in
  *' n-${NODE_NUM}.${ZONE} '*|*' n-${NODE_NUM}g.${ZONE} '*) ;;
  *) exit 0 ;;
esac
/usr/bin/docker inspect "\$CONTAINER" >/dev/null
/usr/bin/docker exec "\$CONTAINER" nginx -t
/usr/bin/docker exec "\$CONTAINER" nginx -s reload
EOF
  else
    cat >"$HOOK_PATH" <<EOF
#!/bin/sh
set -eu
COMPOSE_DIR='$COMPOSE_DIR'
SERVICE='$NGINX_SERVICE'
case " \${RENEWED_DOMAINS:-} " in
  *' n-${NODE_NUM}.${ZONE} '*|*' n-${NODE_NUM}g.${ZONE} '*) ;;
  *) exit 0 ;;
esac
cd "\$COMPOSE_DIR"
/usr/bin/docker compose up -d --force-recreate --no-deps "\$SERVICE"
EOF
  fi

  chmod 700 "$HOOK_PATH"
  log "Deploy hook installed: $HOOK_PATH ($HOOK_MODE mode)"
}

certbot_has_reconfigure() {
  certbot --help all 2>/dev/null | grep -qE '^[[:space:]]*reconfigure[[:space:]]'
}

fallback_certonly_existing() {
  local name=$1 d
  local -a args=(certbot certonly --non-interactive --dns-cloudflare --dns-cloudflare-credentials "$CF_CREDS" --dns-cloudflare-propagation-seconds 30 --cert-name "$name")
  local count=0
  while IFS= read -r d; do
    [[ -n $d ]] || continue
    args+=(-d "$d")
    ((count+=1))
  done < <(cert_domains "$name")
  ((count > 0)) || die "Cannot determine SANs for $name; refusing to replace it."
  "${args[@]}"
}

migrate_lineage() {
  local name=$1
  log "Migrating $name to Cloudflare DNS-01..."

  if certbot_has_reconfigure; then
    if certbot reconfigure \
      --non-interactive \
      --cert-name "$name" \
      --dns-cloudflare \
      --dns-cloudflare-credentials "$CF_CREDS" \
      --dns-cloudflare-propagation-seconds 30; then
      return 0
    fi
    warn "reconfigure failed for $name; falling back to certonly while preserving all SANs."
  fi

  fallback_certonly_existing "$name"
  FALLBACK_ISSUED["$name"]=1
}

create_combined_certificate() {
  local d1="n-${NODE_NUM}.${ZONE}" d2="n-${NODE_NUM}g.${ZONE}" email
  warn "No relevant lineages exist. A new combined certificate can be created for:"
  printf '  - %s\n  - %s\n' "$d1" "$d2"
  confirm "Create it now?" Y || die "Nothing to migrate."

  local -a args=(certbot certonly --dns-cloudflare --dns-cloudflare-credentials "$CF_CREDS" --dns-cloudflare-propagation-seconds 30 --cert-name "$d1" -d "$d1" -d "$d2")

  if [[ ! -d /etc/letsencrypt/accounts ]] || ! find /etc/letsencrypt/accounts -type f -name regr.json -print -quit 2>/dev/null | grep -q .; then
    read -r -p "Email for Let's Encrypt account: " email
    [[ $email == *@* ]] || die "A valid email is required for first Certbot registration."
    args+=(--email "$email" --agree-tos --no-eff-email)
  else
    args+=(--non-interactive)
  fi

  "${args[@]}"
  RELEVANT=("$d1")
  FALLBACK_ISSUED["$d1"]=1
}

renew_due_lineages() {
  local name status
  for name in "${RELEVANT[@]}"; do
    [[ ${FALLBACK_ISSUED[$name]:-0} == 1 ]] && { info "$name was already issued during migration; skipping extra production renewal."; continue; }
    status=$(cert_status "$name")
    case "$status" in
      EXPIRED|EXPIRING*)
        log "$name is $status -> issuing a fresh production certificate now."
        certbot renew --non-interactive --cert-name "$name" --force-renewal
        ;;
      *)
        info "$name is $status -> no forced production renewal needed."
        ;;
    esac
  done
}

enable_renew_timer() {
  if systemctl list-unit-files 2>/dev/null | grep -qE '^certbot\.timer'; then
    systemctl enable --now certbot.timer
    log "certbot.timer enabled."
    systemctl status certbot.timer --no-pager -l | sed -n '1,8p' || true
  elif systemctl list-unit-files 2>/dev/null | grep -qE '^snap\.certbot\.renew\.timer'; then
    systemctl enable --now snap.certbot.renew.timer || true
    log "snap.certbot.renew.timer is present."
  else
    warn "No known Certbot systemd timer found. Check your Certbot installation's renewal scheduler."
  fi
}

dry_run_relevant() {
  local name failures=0
  for name in "${RELEVANT[@]}"; do
    log "Dry-run: $name"
    if ! certbot renew --dry-run --run-deploy-hooks --cert-name "$name"; then
      failures=$((failures + 1))
    fi
  done
  ((failures == 0)) || die "$failures dry-run(s) failed. Review output before considering the node finished."
}

maybe_cleanup_legacy() {
  local legacy="node-${NODE_NUM}.${ZONE}"
  [[ -f /etc/letsencrypt/renewal/$legacy.conf ]] || return 0

  printf '\n'
  warn "Legacy ignored certificate still exists: $legacy"
  warn "If left in Certbot, the stock timer can still attempt to renew it and log failures."
  confirm "Remove $legacy from Certbot if it is unused?" N || return 0

  local refs=''
  if [[ -d ${COMPOSE_DIR:-/nonexistent} ]]; then
    refs=$(grep -R -n -F "$legacy" "$COMPOSE_DIR" 2>/dev/null || true)
  fi
  if [[ -n $refs ]]; then
    warn "Refusing to delete: references were found under $COMPOSE_DIR:"
    printf '%s\n' "$refs"
    return 0
  fi

  certbot delete --non-interactive --cert-name "$legacy"
  log "Deleted unused legacy Certbot lineage $legacy."
}

final_report() {
  printf '\n================ FINAL REPORT ================\n'
  scan_certificates
  printf '\nCloudflare renewal settings:\n'
  for name in "${RELEVANT[@]}"; do
    local conf="/etc/letsencrypt/renewal/$name.conf"
    [[ -r $conf ]] || continue
    printf '\n[%s]\n' "$name"
    grep -E '^(authenticator|dns_cloudflare_credentials|dns_cloudflare_propagation_seconds) = ' "$conf" || true
  done

  printf '\nDocker nginx:\n'
  docker ps --filter "name=$NGINX_CONTAINER" --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' || true
  if docker inspect "$NGINX_CONTAINER" >/dev/null 2>&1; then
    if docker exec "$NGINX_CONTAINER" nginx -t; then
      log "nginx configuration test OK."
    else
      warn "nginx configuration test FAILED."
    fi
  fi
  printf '\nDeploy hook: %s (%s)\n' "$HOOK_PATH" "$HOOK_MODE"
  printf '================================================\n'
}

main() {
  require_root
  install_certbot_if_needed
  have openssl || die "openssl is required."
  have docker || die "docker is required for nginx automation."

  detect_identity
  TARGET1="n-${NODE_NUM}.${ZONE}"
  TARGET2="n-${NODE_NUM}g.${ZONE}"

  info "Target domains: $TARGET1 and $TARGET2"
  info "Renew-now threshold: <= ${RENEW_WITHIN_DAYS} days"

  # Requirement: inspect certificate state before asking for secrets.
  scan_certificates
  check_dns

  printf '\nThis will migrate relevant certificates to Cloudflare DNS-01, install a deploy hook,\nand configure automated renewal. The legacy node-${NODE_NUM}.${ZONE} lineage is ignored unless you explicitly delete it later.\n\n'
  confirm "Continue?" Y || exit 0

  ensure_cloudflare_plugin
  get_cloudflare_credentials
  detect_docker_context
  install_deploy_hook

  declare -gA FALLBACK_ISSUED=()

  if ((${#RELEVANT[@]} == 0)); then
    create_combined_certificate
  else
    local name
    for name in "${RELEVANT[@]}"; do
      migrate_lineage "$name"
    done
  fi

  renew_due_lineages
  enable_renew_timer

  # Test only relevant lineages, so intentionally ignored node-N cannot break the test.
  dry_run_relevant
  maybe_cleanup_legacy
  final_report

  log "Finished successfully."
}

main "$@"
