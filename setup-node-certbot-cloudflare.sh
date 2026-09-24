#!/usr/bin/env bash
set -Eeuo pipefail

# remnawave-certbot
# Universal Certbot + Cloudflare DNS-01 setup for Remnawave nodes.
# Ubuntu / Debian oriented, Docker Compose aware.

SCRIPT_VERSION="2.2.3"
PROG=${0##*/}

# ---- Defaults ----------------------------------------------------------------
DEFAULT_ZONE=${DEFAULT_ZONE:-argent-projects.com}
DEFAULT_COMPOSE_DIR=${DEFAULT_COMPOSE_DIR:-/opt/remnanode}
DEFAULT_NGINX_CONTAINER=${DEFAULT_NGINX_CONTAINER:-remnawave-nginx}
DEFAULT_CF_CREDS=${DEFAULT_CF_CREDS:-/root/.secrets/certbot/cloudflare.ini}
RENEW_WITHIN_DAYS=${RENEW_WITHIN_DAYS:-30}
PROPAGATION_SECONDS=${PROPAGATION_SECONDS:-60}
RETRY_PROPAGATION_SECONDS=${RETRY_PROPAGATION_SECONDS:-120}
DRY_RUN_RETRY_DELAY=${DRY_RUN_RETRY_DELAY:-20}
DRY_RUN_MAX_ATTEMPTS=${DRY_RUN_MAX_ATTEMPTS:-3}
HOOK_PATH=${HOOK_PATH:-/etc/letsencrypt/renewal-hooks/deploy/reload-remnawave-nginx.sh}
LOG_DIR=${LOG_DIR:-/var/log/remnawave-certbot}

MODE="menu"
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
TARGET_LINEAGES=()
UNUSED_LINEAGES=()
SUMMARY_OK=()
SUMMARY_WARN=()
SUMMARY_FAIL=()
declare -A FALLBACK_ISSUED=()
declare -A STAGING_TESTED=()
declare -A PRODUCTION_RENEWED=()
declare -A LINEAGE_USAGE=()
declare -A LINEAGE_USAGE_REASON=()
LAST_TASK_OUTPUT=""
TLS_TOPOLOGY="unknown"
TLS_443_OWNER=""
TLS_443_PID=""
NGINX_CONTAINER_PID=""
NGINX_LISTEN_SUMMARY=""

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
  ui_line "${CYAN}${BOLD}╭──────────────────────────────────────────────────────────────╮${RESET}"
  ui_line "${CYAN}${BOLD}  Remnawave Certbot · Cloudflare DNS-01${RESET}"
  ui_line "${DIM}  Интерактивный аудит и настройка ноды · v${SCRIPT_VERSION}${RESET}"
  ui_line "${CYAN}${BOLD}╰──────────────────────────────────────────────────────────────╯${RESET}"
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

# Interactive input must come from the controlling terminal, not stdin.
# This keeps prompts working when launched as: curl .../install.sh | bash
tty_read() {
  if [[ -r /dev/tty ]]; then
    IFS= read "$@" </dev/tty
  else
    IFS= read "$@"
  fi
}

usage() {
  cat <<EOF
Использование: $PROG [параметры]

Режимы:
  без параметров               Показать интерактивное меню
  --audit                      Только аудит, без изменений
  --apply                      Применить настройку и исправления

Параметры:
  --yes, -y                    Принимать безопасные значения по умолчанию
  --cleanup-legacy             Удалить неиспользуемый legacy node-N, если это безопасно
  --skip-dry-run               Пропустить финальные staging-тесты Let's Encrypt
  --node N                     Явно указать номер ноды
  --zone DOMAIN                Явно указать DNS-зону
  --credentials PATH           Путь к credentials Cloudflare
  --compose-dir PATH           Каталог Docker Compose
  --nginx-container NAME       Имя nginx-контейнера
  --nginx-service NAME         Имя nginx-сервиса Docker Compose
  --propagation SECONDS        Ожидание DNS propagation (по умолчанию: $PROPAGATION_SECONDS)
  -h, --help                   Показать эту справку

Примеры:
  $PROG
  $PROG --audit
  $PROG --apply --yes
  $PROG --apply --node 6 --zone argent-projects.com
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --audit) MODE="audit" ;;
      --apply) MODE="apply" ;;
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
      *) fatal "Неизвестный параметр: $1" ;;
    esac
    shift
  done

  [[ $PROPAGATION_SECONDS =~ ^[0-9]+$ ]] || fatal "Значение propagation должно быть целым числом."
  ((PROPAGATION_SECONDS >= 10)) || fatal "Значение propagation должно быть не меньше 10 секунд."
  if ((RETRY_PROPAGATION_SECONDS < PROPAGATION_SECONDS)); then
    RETRY_PROPAGATION_SECONDS=$PROPAGATION_SECONDS
  fi
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fatal "Запустите скрипт от root: sudo -i, затем повторите команду."
}

init_log() {
  mkdir -p "$LOG_DIR"
  chmod 700 "$LOG_DIR"
  LOG_FILE="$LOG_DIR/setup-$(date '+%Y%m%d-%H%M%S').log"
  : >"$LOG_FILE"
  chmod 600 "$LOG_FILE"
  printf 'remnawave-certbot v%s\nзапуск: %s\n\n' "$SCRIPT_VERSION" "$(date -Is)" >>"$LOG_FILE"
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
  LAST_TASK_OUTPUT=$(tail -n 80 "$tmp" 2>/dev/null || true)
  if ((rc == 0)); then
    ok "$label"
  else
    fail "$label"
    printf '%b%s%b\n' "$DIM" "  Последний вывод:" "$RESET" >&2
    tail -n 18 "$tmp" | sed 's/^/    /' >&2
    note "Полный лог: $LOG_FILE"
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
  warn "Остановлено пользователем${CURRENT_TASK:+ во время: $CURRENT_TASK}. Ctrl+C не считается ошибкой проверки."
  exit 130
}
trap on_interrupt INT TERM

prompt_default() {
  local __var=$1 prompt=$2 def=$3 value
  if ((ASSUME_YES)); then
    printf -v "$__var" '%s' "$def"
    return
  fi
  tty_read -r -p "$prompt [$def]: " value
  printf -v "$__var" '%s' "${value:-$def}"
}

confirm() {
  local prompt=$1 def=${2:-N} answer suffix
  if ((ASSUME_YES)); then
    [[ $def == Y ]]
    return
  fi
  [[ $def == Y ]] && suffix='[Y/n]' || suffix='[y/N]'
  tty_read -r -p "$prompt $suffix " answer
  answer=${answer:-$def}
  [[ $answer =~ ^[Yy]$ ]]
}

# ---- Interactive mode ---------------------------------------------------------
choose_mode() {
  [[ $MODE != menu ]] && {
    if [[ $MODE == audit ]]; then
      info "Режим: аудит без изменений"
    else
      info "Режим: настройка и исправления"
    fi
    return 0
  }

  if ((ASSUME_YES)); then
    fatal "Для неинтерактивного запуска с --yes укажите режим явно: --audit или --apply."
  fi

  section "Режим работы"
  ui_line "${BOLD}Что вы хотите сделать?${RESET}"
  printf '  %b1%b) %bАудит%b\n' "$CYAN$BOLD" "$RESET" "$BOLD" "$RESET"
  note "Проверить сертификаты, DNS, hook и таймер. Без изменений."
  printf '  %b2%b) %bНастройка и исправления%b\n' "$CYAN$BOLD" "$RESET" "$BOLD" "$RESET"
  note "Настроить DNS-01, nginx hook и автоматическое продление."
  printf '  %b0%b) Выход\n' "$GRAY$BOLD" "$RESET"
  printf '\n'

  local choice cleaned
  while :; do
    tty_read -r -p "Выберите действие [1]: " choice
    choice=${choice:-1}

    # SSH terminals can leave ANSI escape sequences (for example from arrow
    # keys) in the input buffer.  Keep only the meaningful menu digits so an
    # accidental Up/Down key immediately before the answer does not turn "1"
    # into something like $'\e[A1'.
    cleaned=${choice//$'\e[A'/}
    cleaned=${cleaned//$'\e[B'/}
    cleaned=${cleaned//$'\e[C'/}
    cleaned=${cleaned//$'\e[D'/}
    cleaned=${cleaned//[[:space:]]/}
    if [[ $cleaned =~ ([012])$ ]]; then
      choice=${BASH_REMATCH[1]}
    else
      choice=$cleaned
    fi

    case "$choice" in
      1)
        MODE="audit"
        ok "Выбран режим: аудит без изменений"
        break
        ;;
      2)
        MODE="apply"
        ok "Выбран режим: настройка и исправления"
        break
        ;;
      0)
        info "Выход без изменений."
        exit 0
        ;;
      *)
        warn "Введите 1, 2 или 0."
        ;;
    esac
  done
}

# ---- Dependencies -------------------------------------------------------------
install_certbot_if_needed() {
  have certbot && return 0
  [[ $MODE == audit ]] && fatal "Certbot не установлен."
  have apt-get || fatal "Certbot не установлен, а apt-get недоступен."
  run_task "Обновляю метаданные apt" apt-get update || fatal "apt-get update завершился ошибкой."
  run_task "Устанавливаю Certbot и Cloudflare-плагин" env DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-dns-cloudflare || fatal "Не удалось установить Certbot."
}

ensure_dns_tools() {
  have dig && return 0
  if [[ $MODE == audit ]]; then
    warn "dig не установлен; проверка DNS будет ограничена."
    return 0
  fi
  if have apt-get; then
    run_task "Устанавливаю DNS-утилиты" env DEBIAN_FRONTEND=noninteractive apt-get install -y dnsutils || warn "Не удалось установить dnsutils; продолжаю без dig."
  fi
}

cloudflare_plugin_available() {
  local out
  out=$(certbot plugins 2>/dev/null || true)
  grep -qE '^\* dns-cloudflare$' <<<"$out"
}

ensure_cloudflare_plugin() {
  if cloudflare_plugin_available; then
    ok "Плагин Certbot dns-cloudflare доступен"
    return 0
  fi

  [[ $MODE == audit ]] && { warn "Плагин dns-cloudflare не установлен."; return 1; }
  warn "Плагин Certbot dns-cloudflare не найден."

  local certbot_path
  certbot_path=$(readlink -f "$(command -v certbot)" 2>/dev/null || command -v certbot)

  if [[ $certbot_path == /snap/* ]] && have snap; then
    run_task "Разрешаю root-плагины Certbot" snap set certbot trust-plugin-with-root=ok || return 1
    if ! snap list certbot-dns-cloudflare >/dev/null 2>&1; then
      run_task "Устанавливаю certbot-dns-cloudflare через snap" snap install certbot-dns-cloudflare || return 1
    fi
  elif have apt-get; then
    run_task "Устанавливаю python3-certbot-dns-cloudflare" env DEBIAN_FRONTEND=noninteractive apt-get install -y python3-certbot-dns-cloudflare || return 1
  else
    fatal "Не удалось автоматически установить dns-cloudflare."
  fi

  cloudflare_plugin_available || fatal "После установки dns-cloudflare всё ещё недоступен."
  ok "Плагин Certbot dns-cloudflare доступен"
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
    [[ $NODE_OVERRIDE =~ ^[0-9]+$ ]] || fatal "Некорректный номер ноды: $NODE_OVERRIDE"
    NODE_NUM=$NODE_OVERRIDE
    ZONE=${ZONE_OVERRIDE:-$DEFAULT_ZONE}
    ok "Использую указанную ноду $NODE_NUM · зона $ZONE"
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
    ok "Определена нода $NODE_NUM · зона $ZONE"
    return
  fi

  if ((${#candidates[@]} > 1)); then
    warn "Найдено несколько вариантов ноды/зоны:"
    printf '    %s\n' "${candidates[@]}"
  else
    warn "Не удалось автоматически определить номер ноды из конфигурации Certbot/nginx."
  fi

  tty_read -r -p "Номер ноды (например 5, 6, 13): " NODE_NUM
  [[ $NODE_NUM =~ ^[0-9]+$ ]] || fatal "Некорректный номер ноды: $NODE_NUM"
  if [[ -n $ZONE_OVERRIDE ]]; then ZONE=$ZONE_OVERRIDE; else prompt_default ZONE "DNS-зона" "$DEFAULT_ZONE"; fi
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

lineage_reference_probe() {
  local name=$1 c pid base compose_render mounts nginx_t proc_text
  local -a reasons=()

  # Only active configuration counts as a reference. Historical logs, backups,
  # shell history and Certbot's own files must never keep an obsolete lineage alive.
  base=${COMPOSE_DIR:-$DEFAULT_COMPOSE_DIR}
  for c in \
    "$base/docker-compose.yml" \
    "$base/compose.yml" \
    "$base/compose.yaml" \
    "$base/nginx.conf"; do
    [[ -f $c ]] || continue
    if grep -Fq "$name" "$c" 2>/dev/null; then
      reasons+=("$c")
    fi
  done

  # Capture producer output first. This avoids false negatives from grep -q +
  # pipefail/SIGPIPE on large docker/nginx output.
  if [[ -d $base ]] && have docker; then
    compose_render=$(cd "$base" && docker compose config 2>/dev/null || true)
    if [[ -n $compose_render ]] && grep -Fq "$name" <<<"$compose_render"; then
      reasons+=("docker-compose(active)")
    fi
  fi

  # Docker mounts are one of the strongest signals that a lineage is in use.
  if have docker; then
    while IFS= read -r c; do
      [[ -n $c ]] || continue
      mounts=$(docker inspect "$c" --format '{{range .Mounts}}{{printf "%s -> %s\n" .Source .Destination}}{{end}}' 2>/dev/null || true)
      if [[ -n $mounts ]] && grep -Fq "$name" <<<"$mounts"; then
        reasons+=("mount:$c")
      fi
    done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)

    c=${NGINX_CONTAINER:-${NGINX_CONTAINER_OVERRIDE:-$DEFAULT_NGINX_CONTAINER}}
    if docker inspect "$c" >/dev/null 2>&1; then
      nginx_t=$(docker exec "$c" nginx -T 2>/dev/null || true)
      if [[ -n $nginx_t ]] && grep -Fq "$name" <<<"$nginx_t"; then
        reasons+=("nginx:$c")
      fi
    fi
  fi

  # Some Remnawave topologies have rw-core in front of nginx. Only record a
  # boolean match; never print process environment because it may contain secrets.
  while IFS= read -r pid; do
    [[ -r /proc/$pid/cmdline ]] || continue
    proc_text=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
    if [[ -n $proc_text ]] && grep -Fq "$name" <<<"$proc_text"; then
      reasons+=("rw-core:cmdline")
    fi
    if [[ -r /proc/$pid/environ ]]; then
      proc_text=$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null || true)
      if [[ -n $proc_text ]] && grep -Fq "$name" <<<"$proc_text"; then
        reasons+=("rw-core:env")
      fi
    fi
  done < <(pgrep -x rw-core 2>/dev/null || true)

  if ((${#reasons[@]})); then
    printf '%s\n' "${reasons[@]}" | sort -u | paste -sd, -
  fi
}

add_target_once() {
  local candidate=$1 x
  for x in "${TARGET_LINEAGES[@]:-}"; do [[ $x == "$candidate" ]] && return; done
  TARGET_LINEAGES+=("$candidate")
}

add_unused_once() {
  local candidate=$1 x
  for x in "${UNUSED_LINEAGES[@]:-}"; do [[ $x == "$candidate" ]] && return; done
  UNUSED_LINEAGES+=("$candidate")
}

status_badge() {
  case "$1" in
    VALID) printf '%bДЕЙСТВУЕТ%b' "$GREEN" "$RESET" ;;
    EXPIRING) printf '%b≤%s ДНЕЙ%b' "$YELLOW" "$RENEW_WITHIN_DAYS" "$RESET" ;;
    EXPIRED) printf '%bПРОСРОЧЕН%b' "$RED" "$RESET" ;;
    BROKEN) printf '%bОШИБКА%b' "$RED" "$RESET" ;;
    *) printf '%s' "$1" ;;
  esac
}

scan_certificates() {
  local f name status expiry auth domains marker refs
  local used_count=0
  RELEVANT=()
  TARGET_LINEAGES=()
  UNUSED_LINEAGES=()
  LINEAGE_USAGE=()
  LINEAGE_USAGE_REASON=()
  LEGACY_NAME="node-${NODE_NUM}.${ZONE}"

  shopt -s nullglob
  for f in /etc/letsencrypt/renewal/*.conf; do
    name=${f##*/}; name=${name%.conf}
    [[ $name == "$LEGACY_NAME" ]] && continue
    if is_relevant_lineage "$name"; then
      add_target_once "$name"
    fi
  done
  shopt -u nullglob

  # Determine actual references before deciding which certificates should be touched.
  for name in "${TARGET_LINEAGES[@]:-}"; do
    refs=$(lineage_reference_probe "$name")
    if [[ -n $refs ]]; then
      LINEAGE_USAGE["$name"]="used"
      LINEAGE_USAGE_REASON["$name"]=$refs
      add_relevant_once "$name"
      ((used_count+=1))
    else
      LINEAGE_USAGE["$name"]="unreferenced"
      add_unused_once "$name"
    fi
  done

  # Conservative fallback: if we cannot prove that any target lineage is used, do not
  # silently exclude all of them. Hidden/non-Docker consumers may exist.
  if ((used_count == 0 && ${#TARGET_LINEAGES[@]} > 0)); then
    warn "Не удалось доказать использование ни одного целевого lineage. Включаю консервативный режим: существующие n-N/n-Ng не будут пропущены."
    RELEVANT=("${TARGET_LINEAGES[@]}")
    UNUSED_LINEAGES=()
    for name in "${TARGET_LINEAGES[@]}"; do LINEAGE_USAGE["$name"]="unknown"; done
    summary_warn "Использование целевых lineage не определено однозначно"
  fi

  shopt -s nullglob
  for f in /etc/letsencrypt/renewal/*.conf; do
    name=${f##*/}; name=${name%.conf}
    status=$(cert_status "$name")
    expiry=$(cert_expiry_date "$name")
    auth=$(cert_authenticator "$name")
    domains=$(cert_domains "$name" | paste -sd, -)
    marker=''

    if [[ $name == "$LEGACY_NAME" ]]; then
      marker=' · legacy: пропущен'
    fi

    printf '  %b●%b %b%s%b\n' "$CYAN" "$RESET" "$BOLD" "$name" "$RESET"
    printf '      Статус: %b · метод: %s · до: %s%s\n' "$(status_badge "$status")" "${auth:--}" "$expiry" "$marker"
    printf '      Домены: %s\n' "${domains:--}"

    if [[ $name != "$LEGACY_NAME" ]] && is_relevant_lineage "$name"; then
      case ${LINEAGE_USAGE[$name]:-unknown} in
        used)
          printf '      Использование: %bИСПОЛЬЗУЕТСЯ%b · %s\n' "$GREEN" "$RESET" "${LINEAGE_USAGE_REASON[$name]}"
          ;;
        unreferenced)
          printf '      Использование: %bАКТИВНЫЕ ССЫЛКИ НЕ НАЙДЕНЫ%b\n' "$YELLOW" "$RESET"
          ;;
        *)
          printf '      Использование: %bНЕ ОПРЕДЕЛЕНО%b · сохранён консервативно\n' "$YELLOW" "$RESET"
          ;;
      esac
    fi
  done
  shopt -u nullglob

  if ((${#RELEVANT[@]})); then
    printf '\n'
    ok "Будут обслуживаться Certbot lineage: ${RELEVANT[*]}"
  else
    printf '\n'
    warn "Не найден существующий используемый lineage для $TARGET1 или $TARGET2."
  fi

  if ((${#UNUSED_LINEAGES[@]})); then
    warn "Найдены lineage без активных ссылок: ${UNUSED_LINEAGES[*]}"
    note "Они не будут мигрироваться/перевыпускаться этим запуском. В конце можно удалить их после повторной проверки ссылок."
    summary_warn "Lineage без активных ссылок: ${UNUSED_LINEAGES[*]}"
  fi

  if [[ -f /etc/letsencrypt/renewal/$LEGACY_NAME.conf ]]; then
    warn "$LEGACY_NAME — legacy-сертификат; он исключён из миграции и dry-run."
    summary_warn "Найден legacy Certbot lineage: $LEGACY_NAME"
  fi
}

# ---- DNS / credentials --------------------------------------------------------
check_dns() {
  have dig || { warn "dig недоступен; проверка DNS пропущена."; summary_warn "Проверка DNS пропущена: нет dig"; return 0; }

  local ns a1 a2 aaaa1 aaaa2
  ns=$(dig NS "$ZONE" +short 2>/dev/null || true)
  if grep -Eqi '\.ns\.cloudflare\.com\.?$' <<<"$ns"; then
    ok "$ZONE обслуживается DNS-серверами Cloudflare"
    summary_ok "Подтверждены authoritative DNS Cloudflare"
  else
    warn "Не удалось подтвердить nameserver Cloudflare для $ZONE."
    [[ -n $ns ]] && printf '%s\n' "$ns" | sed 's/^/    /'
    summary_warn "Authoritative DNS Cloudflare не подтверждён"
    [[ $MODE == audit ]] && return 0
    confirm "Продолжить несмотря на предупреждение DNS?" N || exit 1
  fi

  a1=$(dig +short "$TARGET1" A | paste -sd, -)
  a2=$(dig +short "$TARGET2" A | paste -sd, -)
  aaaa1=$(dig +short "$TARGET1" AAAA | paste -sd, -)
  aaaa2=$(dig +short "$TARGET2" AAAA | paste -sd, -)

  printf '    %-36s A=%-20s AAAA=%s\n' "$TARGET1" "${a1:--}" "${aaaa1:--}"
  printf '    %-36s A=%-20s AAAA=%s\n' "$TARGET2" "${a2:--}" "${aaaa2:--}"

  [[ -n $a1 || -n $aaaa1 ]] || { warn "Для $TARGET1 нет A/AAAA-записи."; summary_warn "$TARGET1: нет A/AAAA"; }
  [[ -n $a2 || -n $aaaa2 ]] || { warn "Для $TARGET2 нет A/AAAA-записи."; summary_warn "$TARGET2: нет A/AAAA"; }
}

credentials_valid_format() {
  local file=$1
  [[ -s $file ]] && grep -qE '^[[:space:]]*dns_cloudflare_api_token[[:space:]]*=' "$file"
}

get_cloudflare_credentials() {
  CF_CREDS=${CF_CREDS_OVERRIDE:-$DEFAULT_CF_CREDS}
  [[ -n $CF_CREDS_OVERRIDE ]] || prompt_default CF_CREDS "Файл credentials Cloudflare" "$DEFAULT_CF_CREDS"

  if credentials_valid_format "$CF_CREDS"; then
    if confirm "Использовать существующие credentials Cloudflare: $CF_CREDS?" Y; then
      chmod 600 "$CF_CREDS"
      [[ -d ${CF_CREDS%/*} ]] && chmod 700 "${CF_CREDS%/*}" || true
      ok "Использую существующие credentials Cloudflare"
      return 0
    fi
  elif [[ -e $CF_CREDS ]]; then
    warn "$CF_CREDS существует, но не содержит dns_cloudflare_api_token. Файл не будет использован."
  fi

  local token token2 dir
  dir=${CF_CREDS%/*}
  mkdir -p "$dir"
  chmod 700 "$dir"

  while :; do
    tty_read -r -s -p "Cloudflare API Token (DNS Edit для $ZONE): " token
    printf '\n'
    [[ -n $token ]] || { warn "Токен не может быть пустым."; continue; }
    tty_read -r -s -p "Повторите API Token: " token2
    printf '\n'
    [[ $token == "$token2" ]] || { warn "Токены не совпадают."; token=''; token2=''; continue; }
    break
  done

  umask 077
  printf 'dns_cloudflare_api_token = %s\n' "$token" >"$CF_CREDS"
  chmod 600 "$CF_CREDS"
  token=''; token2=''; unset token token2
  ok "Credentials Cloudflare сохранены с правами 0600"
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

  [[ -n $NGINX_CONTAINER_OVERRIDE ]] || prompt_default NGINX_CONTAINER "nginx-контейнер" "$NGINX_CONTAINER"
  docker inspect "$NGINX_CONTAINER" >/dev/null 2>&1 || fatal "Контейнер $NGINX_CONTAINER не найден."

  local wd service mounts has_full=0 has_individual=0
  wd=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$NGINX_CONTAINER" 2>/dev/null || true)
  service=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.service" }}' "$NGINX_CONTAINER" 2>/dev/null || true)
  [[ -n $wd && $wd != '<no value>' ]] || wd=$DEFAULT_COMPOSE_DIR
  [[ -n $service && $service != '<no value>' ]] || service=$NGINX_CONTAINER

  COMPOSE_DIR=${COMPOSE_DIR_OVERRIDE:-$wd}
  NGINX_SERVICE=${NGINX_SERVICE_OVERRIDE:-$service}
  [[ -n $COMPOSE_DIR_OVERRIDE ]] || prompt_default COMPOSE_DIR "Каталог Docker Compose" "$COMPOSE_DIR"
  [[ -n $NGINX_SERVICE_OVERRIDE ]] || prompt_default NGINX_SERVICE "nginx-сервис Docker Compose" "$NGINX_SERVICE"

  [[ -d $COMPOSE_DIR ]] || fatal "Каталог Docker Compose не существует: $COMPOSE_DIR"
  if ! (cd "$COMPOSE_DIR" && docker compose config >/dev/null 2>&1); then
    fatal "Проверка docker compose config завершилась ошибкой в $COMPOSE_DIR"
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
    ok "Docker: сертификаты смонтированы отдельными файлами → после продления nginx будет пересоздан"
  elif ((has_full)); then
    HOOK_MODE="reload"
    ok "Docker: /etc/letsencrypt смонтирован целиком → после продления nginx будет перезагружен"
  else
    warn "Не удалось определить bind mount сертификатов Certbot для nginx."
    printf '%s\n' "$mounts" | sed 's/^/    /'
    if confirm "Использовать безопасный fallback с пересозданием nginx через Compose?" Y; then
      HOOK_MODE="recreate"
    else
      HOOK_MODE="reload"
    fi
  fi

  if ! run_task "Проверяю текущую конфигурацию nginx" docker exec "$NGINX_CONTAINER" nginx -t; then
    fatal "Текущая конфигурация nginx некорректна; автоматизация продления не будет изменена."
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

printf '%s\n' "nginx не стал готов после пересоздания через Docker Compose" >&2
"\$DOCKER" logs --tail 50 "\$CONTAINER" >&2 || true
exit 1
EOF
  fi

  chmod 700 "$HOOK_PATH"
  if sh -n "$HOOK_PATH"; then
    ok "Deploy-hook установлен: $HOOK_PATH (режим: $HOOK_MODE)"
    summary_ok "Deploy-hook nginx: режим $HOOK_MODE"
  else
    fatal "Сгенерированный deploy-hook не прошёл проверку синтаксиса shell."
  fi
}

# ---- Certbot migration / renewal ---------------------------------------------
certbot_has_reconfigure() {
  local out
  out=$(certbot --help all 2>/dev/null || true)
  grep -qE '^[[:space:]]*reconfigure[[:space:]]' <<<"$out"
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
    ok "$name уже использует Cloudflare DNS-01 (${PROPAGATION_SECONDS}с+)"
    summary_ok "$name: конфигурация продления"
    return 0
  fi

  info "Перевожу $name на Cloudflare DNS-01"

  if certbot_has_reconfigure; then
    if run_task "$name · staging reconfigure (${PROPAGATION_SECONDS}с)" certbot_reconfigure_once "$name" "$PROPAGATION_SECONDS"; then
      STAGING_TESTED["$name"]=1
      summary_ok "$name переведён на Cloudflare DNS-01"
      return 0
    fi

    warn "Первая staging-проверка не прошла. Повторяю с ожиданием ${RETRY_PROPAGATION_SECONDS}с."
    if run_task "$name · повтор staging (${RETRY_PROPAGATION_SECONDS}с)" certbot_reconfigure_once "$name" "$RETRY_PROPAGATION_SECONDS"; then
      STAGING_TESTED["$name"]=1
      summary_ok "$name переведён на Cloudflare DNS-01 (${RETRY_PROPAGATION_SECONDS}с propagation)"
      return 0
    fi
  fi

  warn "Staging reconfigure не прошёл для $name."
  warn "Использую production fallback через certonly с сохранением всех SAN. Может быть выпущен новый сертификат."
  if run_task "$name · production fallback миграции" fallback_certonly_existing "$name" "$RETRY_PROPAGATION_SECONDS"; then
    FALLBACK_ISSUED["$name"]=1
    PRODUCTION_RENEWED["$name"]=1
    summary_warn "$name потребовал production fallback при миграции"
    return 0
  fi

  fatal "Не удалось перевести $name на Cloudflare DNS-01."
}

has_certbot_account() {
  [[ -d /etc/letsencrypt/accounts ]] || return 1
  [[ -n $(find /etc/letsencrypt/accounts -type f -name regr.json -print -quit 2>/dev/null) ]]
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
  warn "Подходящий Certbot lineage не найден. Будет создан объединённый сертификат для:"
  printf '    • %s\n    • %s\n' "$TARGET1" "$TARGET2"
  confirm "Создать объединённый сертификат?" Y || fatal "Сертификат для миграции не выбран."

  if ! has_certbot_account; then
    tty_read -r -p "Email для аккаунта Let's Encrypt: " email
    [[ $email == *@*.* ]] || fatal "Для первой регистрации Let's Encrypt нужен корректный email."
  fi

  run_task "Выпускаю первый объединённый сертификат" create_combined_certificate_cmd "$email" || fatal "Не удалось выпустить первый сертификат."
  RELEVANT=("$TARGET1")
  FALLBACK_ISSUED["$TARGET1"]=1
  PRODUCTION_RENEWED["$TARGET1"]=1
  summary_ok "Первый объединённый сертификат выпущен"
}

renew_due_lineages() {
  local name status
  for name in "${RELEVANT[@]}"; do
    if [[ ${FALLBACK_ISSUED[$name]:-0} == 1 ]]; then
      info "$name уже был выпущен во время миграции; повторный production renewal пропущен"
      continue
    fi

    status=$(cert_status "$name")
    case "$status" in
      EXPIRED|EXPIRING)
        if run_task "$name · production renewal" certbot renew --non-interactive --cert-name "$name" --force-renewal; then
          PRODUCTION_RENEWED["$name"]=1
          summary_ok "$name: свежий production-сертификат"
        else
          fatal "Production renewal завершился ошибкой для $name."
        fi
        ;;
      VALID)
        ok "$name сейчас не требует production renewal"
        ;;
      *) fatal "Некорректное состояние сертификата $name: $status." ;;
    esac
  done
}

systemd_unit_exists() {
  local unit=$1
  systemctl cat --no-pager "$unit" >/dev/null 2>&1
}

enable_renew_timer() {
  local unit=''

  if systemd_unit_exists certbot.timer; then
    unit='certbot.timer'
  elif systemd_unit_exists snap.certbot.renew.timer; then
    unit='snap.certbot.renew.timer'
  fi

  if [[ -z $unit ]]; then
    if [[ -f /etc/cron.d/certbot ]]; then
      ok "Systemd-таймер Certbot не найден, но обнаружен /etc/cron.d/certbot — автопродление уже настроено через cron"
      summary_ok "Автопродление Certbot: cron"
      return 0
    fi
    warn "Не найден ни systemd-таймер Certbot, ни /etc/cron.d/certbot."
    summary_warn "Механизм автопродления Certbot не найден"
    return 0
  fi

  if systemctl is-enabled --quiet "$unit" 2>/dev/null && systemctl is-active --quiet "$unit" 2>/dev/null; then
    ok "$unit уже включён и активен"
    summary_ok "$unit активен"
    return 0
  fi

  run_task "Включаю $unit" systemctl enable --now "$unit" || fatal "Не удалось включить $unit."
  ok "$unit включён и активен"
  summary_ok "$unit включён"
}

test_deploy_hook_once() {
  [[ -x $HOOK_PATH ]] || { warn "Deploy-hook отсутствует или не исполняемый: $HOOK_PATH"; return 1; }
  local name d domains=''
  for name in "${RELEVANT[@]}"; do
    while IFS= read -r d; do
      [[ -n $d ]] || continue
      case " $domains " in *" $d "*) ;; *) domains+="${domains:+ }$d" ;; esac
    done < <(cert_domains "$name")
  done
  [[ -n $domains ]] || domains="$TARGET1"

  if run_task "Проверка deploy-hook nginx" env \
      RENEWED_DOMAINS="$domains" \
      RENEWED_LINEAGE="/etc/letsencrypt/live/${RELEVANT[0]:-$TARGET1}" \
      "$HOOK_PATH"; then
    summary_ok "Deploy-hook nginx выполнен успешно"
    return 0
  fi
  fatal "Deploy-hook nginx не прошёл ручную проверку."
}

is_transient_acme_error() {
  # These responses describe an ACME order/authorization state race rather
  # than a DNS authentication failure.  In particular, orderNotReady can be
  # returned while the CA has not yet transitioned an order from pending to
  # ready.  A fresh Certbot invocation creates a new order and is safe to retry.
  grep -qiE \
    'authorization must be pending|Unable to update challenge|orderNotReady|Order.t? status .*pending.*not acceptable for finalization|badNonce|serverInternal' \
    <<<"${1:-}"
}

run_task_retryable() {
  # Variant of run_task used for expected transient staging failures.  It keeps
  # the full command output in the protected log but avoids a scary red FAIL
  # until we know the error is actually persistent/non-transient.
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
  LAST_TASK_OUTPUT=$(tail -n 80 "$tmp" 2>/dev/null || true)
  rm -f "$tmp"
  CURRENT_TASK=""

  if ((rc == 0)); then
    ok "$label"
    return 0
  fi
  return "$rc"
}

dry_run_with_retry() {
  local name=$1 attempt=1 delay=$DRY_RUN_RETRY_DELAY label rc
  while ((attempt <= DRY_RUN_MAX_ATTEMPTS)); do
    label="$name · staging renewal + deploy-hook (попытка $attempt/$DRY_RUN_MAX_ATTEMPTS)"
    if run_task_retryable "$label" \
      certbot renew --non-interactive --cert-name "$name" --dry-run --run-deploy-hooks; then
      return 0
    else
      rc=$?
    fi

    if is_transient_acme_error "$LAST_TASK_OUTPUT"; then
      if ((attempt < DRY_RUN_MAX_ATTEMPTS)); then
        warn "$name · staging CA вернул временное состояние ACME (order ещё не готов). Повторю новым order через ${delay}с."
        sleep "$delay"
        delay=$((delay * 2))
        ((attempt+=1))
        continue
      fi

      warn "$name · staging CA остаётся во временном состоянии после $DRY_RUN_MAX_ATTEMPTS попыток."
      note "Production-сертификат и renewal-конфигурация не считаются сломанными из-за orderNotReady/authorization-state race. Повторите аудит позже."
      return 2
    fi

    fail "$label"
    printf '%b%s%b\n' "$DIM" "  Последний вывод:" "$RESET" >&2
    printf '%s\n' "$LAST_TASK_OUTPUT" | tail -n 18 | sed 's/^/    /' >&2
    note "Полный лог: $LOG_FILE"
    return "${rc:-1}"
  done
  return 1
}

dry_run_relevant() {
  ((SKIP_DRY_RUN)) && { warn "Финальный dry-run пропущен по запросу."; summary_warn "Dry-run пропущен"; return 0; }

  local name failures=0
  for name in "${RELEVANT[@]}"; do
    if [[ ${PRODUCTION_RENEWED[$name]:-0} == 1 ]]; then
      ok "$name · сквозная проверка уже подтверждена успешным production renewal; повторный staging сразу после выпуска пропущен"
      summary_ok "$name: production renewal подтверждает выпуск"
      continue
    fi

    if [[ ${STAGING_TESTED[$name]:-0} == 1 ]]; then
      ok "$name · staging уже успешно пройден во время reconfigure; повторный order не создаётся"
      summary_ok "$name: staging проверен при reconfigure"
      continue
    fi

    local dry_rc=0
    if dry_run_with_retry "$name"; then
      summary_ok "$name: dry-run"
    else
      dry_rc=$?
      if ((dry_rc == 2)); then
        summary_warn "$name: staging вернул временное состояние ACME; повторить проверку позже"
      else
        ((failures+=1))
        summary_fail "$name: dry-run"
      fi
    fi
  done

  ((failures == 0)) || fatal "Не прошли dry-run: $failures. Подробности: $LOG_FILE"
}

# ---- Cleanup / reporting ------------------------------------------------------
legacy_reference_report() {
  local legacy=$1 refs

  # Reuse the same active-reference detector used by the main audit.
  # Do NOT recursively grep the whole Remnawave directory: access/error logs
  # contain historical Host/Referer values and are not active configuration.
  refs=$(lineage_reference_probe "$legacy")
  [[ -n $refs ]] || return 0
  tr ',' '\n' <<<"$refs"
}

maybe_cleanup_legacy() {
  local legacy=$LEGACY_NAME refs status
  [[ -f /etc/letsencrypt/renewal/$legacy.conf ]] || return 0

  status=$(cert_status "$legacy")
  warn "Остался legacy Certbot lineage: $legacy ($status)"
  refs=$(legacy_reference_report "$legacy")

  if [[ -n $refs ]]; then
    warn "Он используется локальной конфигурацией и НЕ будет удалён:"
    printf '%s' "$refs" | sed 's/^/    /'
    summary_warn "Legacy $legacy сохранён: найдены ссылки"
    return 0
  fi

  note "Ссылки на $legacy не найдены в $COMPOSE_DIR, /etc/nginx и Docker mounts."
  note "Если оставить его, общий таймер Certbot может продолжать попытки продления."

  if ((AUTO_CLEANUP_LEGACY)); then
    :
  elif ! confirm "Удалить неиспользуемый legacy lineage $legacy из Certbot?" N; then
    summary_warn "Неиспользуемый legacy lineage оставлен: $legacy"
    return 0
  fi

  if run_task "Удаляю неиспользуемый legacy lineage $legacy" certbot delete --non-interactive --cert-name "$legacy"; then
    summary_ok "Неиспользуемый legacy lineage удалён"
  else
    summary_warn "Не удалось удалить legacy lineage $legacy"
  fi
}

maybe_cleanup_unused_lineages() {
  local name refs status
  ((${#UNUSED_LINEAGES[@]})) || return 0

  for name in "${UNUSED_LINEAGES[@]}"; do
    [[ -f /etc/letsencrypt/renewal/$name.conf ]] || continue
    refs=$(lineage_reference_probe "$name")
    if [[ -n $refs ]]; then
      warn "$name снова обнаружен в активной конфигурации; удаление отменено: $refs"
      summary_warn "$name сохранён: появились активные ссылки"
      continue
    fi

    status=$(cert_status "$name")
    warn "$name · активные ссылки не найдены · состояние: $status"
    note "Стандартный certbot.timer продолжит обслуживать этот lineage, пока он существует."
    if ! confirm "Удалить неиспользуемый Certbot lineage $name?" N; then
      summary_warn "Неиспользуемый lineage оставлен: $name"
      continue
    fi

    if run_task "Удаляю неиспользуемый lineage $name" certbot delete --non-interactive --cert-name "$name"; then
      summary_ok "Неиспользуемый lineage удалён: $name"
    else
      summary_warn "Не удалось удалить неиспользуемый lineage: $name"
    fi
  done
}

redundant_lineage_notes() {
  local a b d subset
  local -a a_domains=() b_domains=()
  local -A b_set=()

  ((${#RELEVANT[@]} >= 2)) || return 0

  for a in "${RELEVANT[@]}"; do
    mapfile -t a_domains < <(cert_domains "$a" | awk 'NF' | sort -u)
    ((${#a_domains[@]})) || continue

    for b in "${RELEVANT[@]}"; do
      [[ $a == "$b" ]] && continue
      mapfile -t b_domains < <(cert_domains "$b" | awk 'NF' | sort -u)
      ((${#b_domains[@]})) || continue

      b_set=()
      for d in "${b_domains[@]}"; do
        b_set["$d"]=1
      done

      subset=1
      for d in "${a_domains[@]}"; do
        if [[ -z ${b_set["$d"]+x} ]]; then
          subset=0
          break
        fi
      done

      if ((subset)); then
        warn "$a полностью покрывается SAN сертификата $b. Возможно, это дубликат; автоматически он не удаляется."
        note "$a: $(IFS=,; echo "${a_domains[*]}")"
        note "$b: $(IFS=,; echo "${b_domains[*]}")"
        summary_warn "Возможный дубликат lineage: $a (покрывается $b)"
        return 0
      fi
    done
  done
}

detect_tls_topology() {
  local c nginx_t line direct_listen unix_listen
  TLS_TOPOLOGY="unknown"
  TLS_443_OWNER=""
  TLS_443_PID=""
  NGINX_CONTAINER_PID=""
  NGINX_LISTEN_SUMMARY=""

  if have ss; then
    line=$(ss -lntp 2>/dev/null | awk '$4 ~ /:443$/ {print; exit}' || true)
    if [[ -n $line ]]; then
      TLS_443_OWNER=$(sed -n 's/.*users:(("\([^"]*\)".*/\1/p' <<<"$line" | head -n1)
      TLS_443_PID=$(sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' <<<"$line" | head -n1)
      [[ -n $TLS_443_OWNER ]] || TLS_443_OWNER="не определён"
    fi
  fi

  c=${NGINX_CONTAINER:-${NGINX_CONTAINER_OVERRIDE:-$DEFAULT_NGINX_CONTAINER}}
  if have docker && docker inspect "$c" >/dev/null 2>&1; then
    NGINX_CONTAINER_PID=$(docker inspect -f '{{.State.Pid}}' "$c" 2>/dev/null || true)
    nginx_t=$(docker exec "$c" nginx -T 2>/dev/null || true)

    direct_listen=$(grep -E 'listen[[:space:]]+([^;[:space:]]*:)?443([^0-9]|;)' <<<"$nginx_t" | head -n1 | sed 's/^[[:space:]]*//' || true)
    unix_listen=$(grep -E 'listen[[:space:]]+unix:[^;]*ssl' <<<"$nginx_t" | head -n1 | sed 's/^[[:space:]]*//' || true)

    if [[ -n $direct_listen ]]; then
      TLS_TOPOLOGY="nginx-direct"
      NGINX_LISTEN_SUMMARY=$direct_listen
    elif [[ -n $unix_listen ]]; then
      NGINX_LISTEN_SUMMARY=$unix_listen
      if [[ -n $TLS_443_PID ]]; then
        if [[ -n $NGINX_CONTAINER_PID && $TLS_443_PID != "$NGINX_CONTAINER_PID" ]]; then
          TLS_TOPOLOGY="frontend-unix-nginx"
        else
          TLS_TOPOLOGY="unix-nginx-ambiguous"
        fi
      else
        TLS_TOPOLOGY="unix-nginx-no443"
      fi
    fi
  fi
}

show_tls_topology() {
  detect_tls_topology
  case "$TLS_TOPOLOGY" in
    frontend-unix-nginx)
      ok "TLS-топология: TCP/443 обслуживает отдельный frontend, контейнер nginx принимает TLS через Unix-сокет"
      note "TCP/443: ${TLS_443_OWNER:-не определён}${TLS_443_PID:+ · PID $TLS_443_PID}"
      [[ -n $NGINX_LISTEN_SUMMARY ]] && note "nginx: $NGINX_LISTEN_SUMMARY"
      note "Внешний openssl :443 не используется как прямая проверка сертификата контейнера nginx."
      ;;
    unix-nginx-no443)
      ok "TLS-топология: контейнер nginx принимает TLS через Unix-сокет; TCP/443 на хосте не обнаружен"
      [[ -n $NGINX_LISTEN_SUMMARY ]] && note "nginx: $NGINX_LISTEN_SUMMARY"
      ;;
    unix-nginx-ambiguous)
      warn "TLS-топология: nginx принимает TLS через Unix-сокет, но владельца TCP/443 нельзя надёжно отделить от контейнера."
      note "TCP/443: ${TLS_443_OWNER:-не определён}${TLS_443_PID:+ · PID $TLS_443_PID}"
      [[ -n $NGINX_LISTEN_SUMMARY ]] && note "nginx: $NGINX_LISTEN_SUMMARY"
      ;;
    nginx-direct)
      ok "TLS-топология: конфигурация контейнера nginx содержит прямой TCP/443 listener"
      [[ -n $NGINX_LISTEN_SUMMARY ]] && note "nginx: $NGINX_LISTEN_SUMMARY"
      [[ -n $TLS_443_OWNER ]] && note "TCP/443: $TLS_443_OWNER${TLS_443_PID:+ · PID $TLS_443_PID}"
      ;;
    *)
      warn "TLS-топология не определена однозначно${TLS_443_OWNER:+ · TCP/443: $TLS_443_OWNER}${TLS_443_PID:+ · PID $TLS_443_PID}."
      ;;
  esac
}

external_tls_check() {
  local name d out cert
  have openssl || return 0
  detect_tls_topology

  case "$TLS_TOPOLOGY" in
    frontend-unix-nginx|unix-nginx-no443|unix-nginx-ambiguous)
      info "Прямая проверка :443 пропущена: сертификат контейнера nginx проверяется локально, так как его TLS listener — Unix-сокет."
      for name in "${RELEVANT[@]}"; do
        cert="/etc/letsencrypt/live/$name/fullchain.pem"
        [[ -r $cert ]] || continue
        out=$(openssl x509 -in "$cert" -noout -subject -enddate 2>/dev/null || true)
        if [[ -n $out ]]; then
          ok "Локальный сертификат $name читается корректно"
          printf '%s\n' "$out" | sed 's/^/    /'
        fi
      done
      return 0
      ;;
  esac

  have timeout || return 0
  for name in "${RELEVANT[@]}"; do
    while IFS= read -r d; do
      [[ -n $d ]] || continue
      out=$(timeout 8 openssl s_client -connect "$d:443" -servername "$d" </dev/null 2>/dev/null \
        | openssl x509 -noout -enddate -subject 2>/dev/null || true)
      if [[ -n $out ]]; then
        ok "Внешний TLS отвечает для $d"
        printf '%s\n' "$out" | sed 's/^/    /'
      else
        warn "Не удалось получить TLS-сертификат от $d:443."
      fi
    done < <(cert_domains "$name")
  done
}

print_timer_state() {
  if systemctl is-active --quiet certbot.timer 2>/dev/null; then
    local next
    next=$(systemctl list-timers --all --no-legend 2>/dev/null | awk '/certbot\.timer/ {$1=$1; print; exit}')
    ok "certbot.timer активен"
    [[ -n $next ]] && note "$next"
  elif systemctl is-active --quiet snap.certbot.renew.timer 2>/dev/null; then
    ok "snap.certbot.renew.timer активен"
  elif [[ -f /etc/cron.d/certbot ]]; then
    ok "Автопродление Certbot настроено через /etc/cron.d/certbot"
  else
    warn "Механизм автопродления Certbot не найден или не активен."
  fi
}

audit_runtime() {
  section "5 · Состояние автоматизации"

  if cloudflare_plugin_available; then
    ok "Плагин dns-cloudflare установлен"
  else
    warn "Плагин dns-cloudflare не установлен"
  fi

  local name auth creds prop
  for name in "${RELEVANT[@]}"; do
    auth=$(renewal_value "$name" authenticator)
    creds=$(renewal_value "$name" dns_cloudflare_credentials)
    prop=$(renewal_value "$name" dns_cloudflare_propagation_seconds)
    if [[ $auth == dns-cloudflare ]]; then
      if [[ -n $creds && -f $creds && $(stat -c '%a' "$creds" 2>/dev/null || true) == 600 ]]; then
        ok "$name · dns-cloudflare · credentials защищены (0600) · propagation=${prop:-?}с"
      elif [[ -n $creds && -f $creds ]]; then
        warn "$name · credentials Cloudflare существуют, но права отличаются от 0600: $creds"
      else
        warn "$name · dns-cloudflare настроен, но credentials-файл не найден: ${creds:-не указан}"
      fi
    else
      warn "$name · метод продления: ${auth:-не определён}"
    fi
  done

  if [[ -f $HOOK_PATH ]]; then
    if sh -n "$HOOK_PATH" >/dev/null 2>&1; then
      ok "Deploy-hook найден и проходит проверку синтаксиса: $HOOK_PATH"
    else
      warn "Deploy-hook найден, но содержит ошибку синтаксиса: $HOOK_PATH"
    fi
  else
    warn "Deploy-hook Certbot не найден: $HOOK_PATH"
  fi

  if have docker; then
    local c=${NGINX_CONTAINER_OVERRIDE:-$DEFAULT_NGINX_CONTAINER}
    if docker inspect "$c" >/dev/null 2>&1; then
      if docker exec "$c" nginx -t >/dev/null 2>&1; then
        ok "Контейнер $c запущен, nginx -t успешен"
      else
        warn "Контейнер $c найден, но nginx -t не прошёл"
      fi
    else
      warn "Контейнер nginx '$c' не найден"
    fi
  else
    warn "Docker не установлен или недоступен"
  fi

  show_tls_topology
  print_timer_state
}

final_report() {
  section "Финальная проверка"

  local name auth prop expiry status
  for name in "${RELEVANT[@]}"; do
    auth=$(renewal_value "$name" authenticator)
    prop=$(renewal_value "$name" dns_cloudflare_propagation_seconds)
    expiry=$(cert_expiry_date "$name")
    status=$(cert_status "$name")
    if [[ $auth == dns-cloudflare && $status == VALID ]]; then
      ok "$name · действует до $expiry · dns-cloudflare · ${prop:-?}с"
    else
      fail "$name · $status · метод=${auth:-?}"
      summary_fail "$name: финальное состояние"
    fi
  done

  if docker inspect "$NGINX_CONTAINER" >/dev/null 2>&1 && docker exec "$NGINX_CONTAINER" nginx -t >/dev/null 2>&1; then
    ok "$NGINX_CONTAINER запущен, конфигурация nginx корректна"
  else
    fail "Проверка nginx в $NGINX_CONTAINER завершилась ошибкой"
    summary_fail "Проверка nginx"
  fi

  show_tls_topology
  print_timer_state
  external_tls_check

  section "Итог"
  printf '%bУСПЕХ%b  %d\n' "$GREEN$BOLD" "$RESET" "${#SUMMARY_OK[@]}"
  for name in "${SUMMARY_OK[@]:-}"; do [[ -n $name ]] && printf '  %b✔%b %s\n' "$GREEN" "$RESET" "$name"; done

  if ((${#SUMMARY_WARN[@]})); then
    printf '\n%bПРЕДУПРЕЖДЕНИЯ%b  %d\n' "$YELLOW$BOLD" "$RESET" "${#SUMMARY_WARN[@]}"
    for name in "${SUMMARY_WARN[@]}"; do printf '  %b▲%b %s\n' "$YELLOW" "$RESET" "$name"; done
  fi

  if ((${#SUMMARY_FAIL[@]})); then
    printf '\n%bОШИБКИ%b  %d\n' "$RED$BOLD" "$RESET" "${#SUMMARY_FAIL[@]}"
    for name in "${SUMMARY_FAIL[@]}"; do printf '  %b✖%b %s\n' "$RED" "$RESET" "$name"; done
  fi

  printf '\n'
  note "Подробный лог: $LOG_FILE"
  if ((${#SUMMARY_FAIL[@]} == 0)); then
    ok "Настройка ноды успешно завершена"
  else
    fatal "Настройка ноды завершилась с ошибками."
  fi
}

# ---- Main --------------------------------------------------------------------
main() {
  parse_args "$@"
  require_root
  init_log
  banner
  note "Защищённый лог: $LOG_FILE"
  choose_mode

  section "1 · Предварительная проверка"
  install_certbot_if_needed
  have openssl || fatal "Требуется openssl."
  have docker || fatal "Для автоматизации nginx требуется Docker."
  ensure_dns_tools

  section "2 · Определение ноды"
  detect_identity
  TARGET1="n-${NODE_NUM}.${ZONE}"
  TARGET2="n-${NODE_NUM}g.${ZONE}"
  LEGACY_NAME="node-${NODE_NUM}.${ZONE}"
  info "Целевые домены: $TARGET1 · $TARGET2"
  info "Порог продления: ${RENEW_WITHIN_DAYS} дней · ожидание DNS: ${PROPAGATION_SECONDS}с"

  section "3 · Аудит сертификатов"
  scan_certificates

  section "4 · Проверка DNS"
  check_dns

  if [[ $MODE == audit ]]; then
    audit_runtime
    section "Аудит завершён"
    ok "Аудит выполнен. Конфигурация сертификатов и сервисов не изменялась."
    note "Для настройки выберите пункт 2 в главном меню или запустите с --apply."
    note "Подробный лог: $LOG_FILE"
    exit 0
  fi

  printf '\n'
  info "Далее будут настроены Cloudflare DNS-01, deploy-hook nginx и автоматическое продление только для обслуживаемых lineage."
  note "Lineage без активных ссылок не мигрируются автоматически; legacy $LEGACY_NAME также исключён."
  confirm "Продолжить и применить изменения?" Y || exit 0

  section "5 · Cloudflare"
  ensure_cloudflare_plugin || fatal "Требуется плагин dns-cloudflare."
  get_cloudflare_credentials

  section "6 · Docker / nginx"
  detect_docker_context
  install_deploy_hook

  section "7 · Миграция Certbot"
  if ((${#RELEVANT[@]} == 0)); then
    create_combined_certificate
  else
    local name
    for name in "${RELEVANT[@]}"; do migrate_lineage "$name"; done
  fi

  section "8 · Боевые сертификаты"
  renew_due_lineages

  section "9 · Автоматическое продление"
  enable_renew_timer

  section "10 · Сквозная проверка"
  test_deploy_hook_once
  dry_run_relevant

  section "11 · Проверка старых и неиспользуемых сертификатов"
  maybe_cleanup_legacy
  maybe_cleanup_unused_lineages
  redundant_lineage_notes

  final_report
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
