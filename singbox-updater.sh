#!/bin/sh
set -eu

# Edit these only if your setup differs from the defaults.
SERVICE_NAME="${SERVICE_NAME:-sing-box}"
PACKAGE_NAME="${PACKAGE_NAME:-sing-box}"
PACKAGE_MANAGER="${PACKAGE_MANAGER:-auto}"
SERVICE_MANAGER="${SERVICE_MANAGER:-auto}"
CONFIG_FILE="${CONFIG_FILE:-/etc/sing-box/config.json}"
CACHE_DIR="${CACHE_DIR:-/var/cache/singbox-updater}"
LOG_FILE="${LOG_FILE:-/var/log/singbox-updater.log}"
LOCK_PATH="${LOCK_PATH:-${LOCK_FILE:-/tmp/singbox-updater.lock}}"
VERIFY_SECONDS="${VERIFY_SECONDS:-30}"
LOG_LINES="${LOG_LINES:-80}"
PACKAGE_OS="${PACKAGE_OS:-auto}"
PACKAGE_ARCH="${PACKAGE_ARCH:-}"
ROLLBACK_EXIT_CODE="${ROLLBACK_EXIT_CODE:-20}"
PID_NAME="${PID_NAME:-sing-box}"
INIT_SCRIPT="${INIT_SCRIPT:-/etc/init.d/$SERVICE_NAME}"
LOGGER_TAG="${LOGGER_TAG:-singbox-updater}"

RELEASE_REPO="SagerNet/sing-box"
RELEASE_API_BASE="https://api.github.com"
RELEASE_DOWNLOAD_BASE="https://github.com"
RELEASE_ASSET_NAME="sing-box"

CURRENT_VERSION=""
LATEST_VERSION=""
ARCH=""
SING_BOX_BIN=""
ROLLBACK_PACKAGE=""
LOCK_ACQUIRED=0
FORCE_VERSION=""
FORCE_INSTALL=0
LOG_PIPE=""

usage() {
  cat <<'USAGE'
Usage: singbox-updater
       singbox-updater --force VERSION

Defaults:
  config file: /etc/sing-box/config.json
  package:     sing-box
  service:     sing-box

Options:
  --force VERSION  install the specified release package only; skip post-install
                   config check, service restart, and automatic rollback
  -h, --help       show this help

Optional overrides:
  PACKAGE_MANAGER=deb|apk
  SERVICE_MANAGER=systemd|initd
  PACKAGE_ARCH=aarch64_cortex-a53
  VERIFY_SECONDS=30
USAGE
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --force|--force-version)
        if [ -z "${2:-}" ]; then
          printf '%s\n' "ERROR: $1 requires a version argument" >&2
          usage >&2
          exit 1
        fi
        FORCE_VERSION="$(normalize_version "$2")"
        FORCE_INSTALL=1
        shift 2
        ;;
      --force=*)
        FORCE_VERSION="$(normalize_version "${1#*=}")"
        FORCE_INSTALL=1
        shift
        ;;
      --force-version=*)
        FORCE_VERSION="$(normalize_version "${1#*=}")"
        FORCE_INSTALL=1
        shift
        ;;
      *)
        printf '%s\n' "ERROR: unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

timestamp() {
  date '+%Y-%m-%d %H:%M:%S%z'
}

log() {
  local message

  message="[$(timestamp)] $*"
  printf '%s\n' "$message" >&2
  if command -v logger >/dev/null 2>&1; then
    logger -t "$LOGGER_TAG" -- "$*" >/dev/null 2>&1 || true
  fi
}

die() {
  log "ERROR: $*"
  exit 1
}

cleanup() {
  if [ "$LOCK_ACQUIRED" = "1" ] && [ -d "$LOCK_PATH" ]; then
    rm -f "$LOCK_PATH/pid" 2>/dev/null || true
    rmdir "$LOCK_PATH" 2>/dev/null || true
  fi
  if [ -n "$LOG_PIPE" ] && [ -p "$LOG_PIPE" ]; then
    rm -f "$LOG_PIPE" 2>/dev/null || true
  fi
}

trap cleanup EXIT HUP INT TERM

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "must run as root"
  fi
}

setup_logging() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  LOG_PIPE="${TMPDIR:-/tmp}/singbox-updater.log.$$"
  if command -v tee >/dev/null 2>&1 && command -v mkfifo >/dev/null 2>&1 &&
    mkfifo "$LOG_PIPE" 2>/dev/null; then
    tee -a "$LOG_FILE" <"$LOG_PIPE" &
    exec >"$LOG_PIPE" 2>&1
    rm -f "$LOG_PIPE"
  else
    log "WARN: failed to create log pipe; output will be written to log file only"
    exec >>"$LOG_FILE" 2>&1
  fi
}

acquire_lock() {
  local lock_pid

  mkdir -p "$(dirname "$LOCK_PATH")"

  if mkdir "$LOCK_PATH" 2>/dev/null; then
    LOCK_ACQUIRED=1
    printf '%s\n' "$$" >"$LOCK_PATH/pid"
    return 0
  fi

  lock_pid=""
  if [ -f "$LOCK_PATH/pid" ]; then
    lock_pid="$(cat "$LOCK_PATH/pid" 2>/dev/null || true)"
  fi

  if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
    log "another update process is running; exit"
    exit 0
  fi

  log "stale lock found; replacing: $LOCK_PATH"
  rm -rf "$LOCK_PATH"
  if ! mkdir "$LOCK_PATH" 2>/dev/null; then
    die "failed to acquire lock: $LOCK_PATH"
  fi

  LOCK_ACQUIRED=1
  printf '%s\n' "$$" >"$LOCK_PATH/pid"
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
}

detect_runtime() {
  if [ "$PACKAGE_MANAGER" = "auto" ]; then
    if command -v dpkg-query >/dev/null 2>&1; then
      PACKAGE_MANAGER="deb"
    elif command -v apk >/dev/null 2>&1; then
      PACKAGE_MANAGER="apk"
    else
      die "failed to detect package manager; set PACKAGE_MANAGER=deb or apk"
    fi
  fi

  case "$PACKAGE_MANAGER" in
    deb|apk)
      ;;
    *)
      die "unsupported PACKAGE_MANAGER: $PACKAGE_MANAGER"
      ;;
  esac

  if [ "$SERVICE_MANAGER" = "auto" ]; then
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
      SERVICE_MANAGER="systemd"
    elif [ -x "$INIT_SCRIPT" ] || [ -d /etc/init.d ]; then
      SERVICE_MANAGER="initd"
    else
      die "failed to detect service manager; set SERVICE_MANAGER=systemd or initd"
    fi
  fi

  case "$SERVICE_MANAGER" in
    systemd|initd)
      ;;
    *)
      die "unsupported SERVICE_MANAGER: $SERVICE_MANAGER"
      ;;
  esac

  if [ "$PACKAGE_OS" = "auto" ]; then
    case "$PACKAGE_MANAGER" in
      deb) PACKAGE_OS="linux" ;;
      apk) PACKAGE_OS="openwrt" ;;
    esac
  fi

  log "runtime: package_manager=$PACKAGE_MANAGER service_manager=$SERVICE_MANAGER package_os=$PACKAGE_OS"
}

curl_api() {
  local url="$1"

  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    "$url"
}

curl_download() {
  local url="$1"
  local output="$2"

  curl -fL --retry 3 --retry-delay 2 --show-error \
    -o "$output" "$url"
}

normalize_version() {
  local version="$1"
  version="${version#v}"
  printf '%s\n' "$version"
}

detect_arch() {
  ARCH=""

  if [ -n "$PACKAGE_ARCH" ]; then
    ARCH="$PACKAGE_ARCH"
    return 0
  fi

  case "$PACKAGE_MANAGER" in
    deb)
      ARCH="$(dpkg --print-architecture)"
      ;;
    apk)
      if [ -r /etc/openwrt_release ]; then
        # shellcheck disable=SC1091
        . /etc/openwrt_release
        ARCH="${DISTRIB_ARCH:-}"
      fi
      if [ -z "$ARCH" ] && command -v apk >/dev/null 2>&1; then
        ARCH="$(apk --print-arch 2>/dev/null | awk 'NF { print; exit }' || true)"
      fi
      ;;
  esac

  if [ -z "$ARCH" ]; then
    die "failed to detect package architecture"
  fi
}

detect_sing_box_binary() {
  SING_BOX_BIN="$(command -v sing-box || true)"
  if [ -z "$SING_BOX_BIN" ]; then
    die "sing-box binary not found in PATH"
  fi
}

ensure_package_installed() {
  local status

  case "$PACKAGE_MANAGER" in
    deb)
      status="$(dpkg-query -W -f='${Status}' "$PACKAGE_NAME" 2>/dev/null || true)"
      if [ "$status" != "install ok installed" ]; then
        die "Debian package is not installed: $PACKAGE_NAME"
      fi
      ;;
    apk)
      if apk info -e "$PACKAGE_NAME" >/dev/null 2>&1; then
        return 0
      fi
      if apk list -I "$PACKAGE_NAME" 2>/dev/null |
        awk -v pkg="$PACKAGE_NAME" 'index($1, pkg "-") == 1 { found = 1 } END { exit(found ? 0 : 1) }'; then
        return 0
      fi
      die "APK package is not installed: $PACKAGE_NAME"
      ;;
  esac
}

detect_current_version() {
  local version_output

  version_output="$("$SING_BOX_BIN" version 2>/dev/null || true)"
  CURRENT_VERSION="$(
    printf '%s\n' "$version_output" |
      awk '/^sing-box version / { print $3; exit }'
  )"
  CURRENT_VERSION="$(normalize_version "$CURRENT_VERSION")"

  if [ -z "$CURRENT_VERSION" ]; then
    die "failed to parse current sing-box version"
  fi
}

parse_first_prerelease_tag() {
  if command -v jq >/dev/null 2>&1; then
    jq -r 'map(select(.draft == false and .prerelease == true) | .tag_name | sub("^v"; ""))[0] // empty'
    return
  fi

  awk '
    /"tag_name"[[:space:]]*:/ {
      tag = $0
      sub(/^.*"tag_name"[[:space:]]*:[[:space:]]*"/, "", tag)
      sub(/".*$/, "", tag)
    }
    /"draft"[[:space:]]*:[[:space:]]*true/ {
      draft = 1
    }
    /"draft"[[:space:]]*:[[:space:]]*false/ {
      draft = 0
    }
    /"prerelease"[[:space:]]*:[[:space:]]*true/ {
      if (first == "" && tag != "" && draft != 1) {
        sub(/^v/, "", tag)
        first = tag
      }
    }
    END {
      if (first != "") {
        print first
      }
    }
  '
}

fetch_latest_beta_version() {
  local page
  local api_url
  local releases_json
  local parsed_version

  for page in 1 2 3 4 5; do
    api_url="${RELEASE_API_BASE}/repos/${RELEASE_REPO}/releases?per_page=30&page=${page}"
    if ! releases_json="$(curl_api "$api_url")"; then
      log "WARN: failed to fetch GitHub releases page $page"
      if [ "$page" = "1" ]; then
        log "ERROR: first GitHub releases page is unavailable; refusing to use older pages as latest"
        return 1
      fi
      continue
    fi

    parsed_version="$(printf '%s\n' "$releases_json" | parse_first_prerelease_tag)"
    if [ -n "$parsed_version" ]; then
      LATEST_VERSION="$(normalize_version "$parsed_version")"
      return 0
    fi
  done

  return 1
}

package_filename() {
  local version="$1"

  case "$PACKAGE_MANAGER" in
    deb)
      printf '%s_%s_%s_%s.deb\n' "$RELEASE_ASSET_NAME" "$version" "$PACKAGE_OS" "$ARCH"
      ;;
    apk)
      printf '%s_%s_%s_%s.apk\n' "$RELEASE_ASSET_NAME" "$version" "$PACKAGE_OS" "$ARCH"
      ;;
  esac
}

package_url() {
  local version="$1"
  local file_name

  file_name="$(package_filename "$version")"
  printf '%s/%s/releases/download/v%s/%s\n' \
    "$RELEASE_DOWNLOAD_BASE" "$RELEASE_REPO" "$version" "$file_name"
}

verify_deb() {
  local deb_path="$1"
  local package_field
  local arch_field
  local version_field

  package_field="$(dpkg-deb -f "$deb_path" Package 2>/dev/null || true)"
  arch_field="$(dpkg-deb -f "$deb_path" Architecture 2>/dev/null || true)"
  version_field="$(dpkg-deb -f "$deb_path" Version 2>/dev/null || true)"

  if [ "$package_field" != "$PACKAGE_NAME" ]; then
    log "ERROR: package mismatch in $deb_path: expected $PACKAGE_NAME, got ${package_field:-unknown}"
    return 1
  fi

  if [ "$arch_field" != "$ARCH" ] && [ "$arch_field" != "all" ]; then
    log "ERROR: architecture mismatch in $deb_path: expected $ARCH, got ${arch_field:-unknown}"
    return 1
  fi

  if [ -z "$version_field" ]; then
    log "ERROR: failed to read package version from $deb_path"
    return 1
  fi

  log "verified package: $package_field $version_field $arch_field"
}

verify_apk() {
  local apk_path="$1"

  if [ ! -s "$apk_path" ]; then
    log "ERROR: package file is empty or missing: $apk_path"
    return 1
  fi

  case "$apk_path" in
    *.apk)
      ;;
    *)
      log "ERROR: unexpected APK package suffix: $apk_path"
      return 1
      ;;
  esac

  if apk add --help 2>&1 | grep -q -- '--simulate'; then
    if ! apk add --allow-untrusted --simulate "$apk_path" >/dev/null 2>&1; then
      log "ERROR: apk simulation failed: $apk_path"
      return 1
    fi
    log "verified apk install simulation: $apk_path"
  else
    log "verified apk package file: $apk_path"
  fi
}

verify_package() {
  local package_path="$1"

  case "$PACKAGE_MANAGER" in
    deb) verify_deb "$package_path" ;;
    apk) verify_apk "$package_path" ;;
  esac
}

debian_package_version_from_release() {
  local version="$1"

  case "$version" in
    *-*)
      printf '%s~%s\n' "${version%%-*}" "${version#*-}"
      ;;
    *)
      printf '%s\n' "$version"
      ;;
  esac
}

ensure_not_downgrade() {
  local current_package_version
  local latest_package_version

  case "$PACKAGE_MANAGER" in
    deb)
      current_package_version="$(debian_package_version_from_release "$CURRENT_VERSION")"
      latest_package_version="$(debian_package_version_from_release "$LATEST_VERSION")"
      if dpkg --compare-versions "$latest_package_version" lt "$current_package_version"; then
        die "refusing to downgrade: current=$CURRENT_VERSION candidate=$LATEST_VERSION"
      fi
      ;;
    apk)
      ;;
  esac
}

ensure_cached_package() {
  local version="$1"
  local dest_dir
  local dest_path
  local tmp_path
  local url

  dest_dir="${CACHE_DIR}/packages"
  mkdir -p "$dest_dir"

  dest_path="${dest_dir}/$(package_filename "$version")"
  if [ -s "$dest_path" ] && verify_package "$dest_path"; then
    printf '%s\n' "$dest_path"
    return 0
  fi

  if [ -e "$dest_path" ]; then
    log "cached package is invalid; redownloading: $dest_path"
  fi

  tmp_path="${dest_path}.tmp.$$"
  url="$(package_url "$version")"
  log "downloading package: $url"
  if ! curl_download "$url" "$tmp_path"; then
    rm -f "$tmp_path"
    return 1
  fi

  if ! verify_package "$tmp_path"; then
    rm -f "$tmp_path"
    return 1
  fi

  if ! mv -f "$tmp_path" "$dest_path"; then
    rm -f "$tmp_path"
    return 1
  fi

  printf '%s\n' "$dest_path"
}

run_config_check() {
  "$SING_BOX_BIN" check -c "$CONFIG_FILE"
}

is_number() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

service_restart_count() {
  if [ "$SERVICE_MANAGER" = "systemd" ]; then
    systemctl show "$SERVICE_NAME" -p NRestarts --value 2>/dev/null || true
  else
    printf '\n'
  fi
}

service_pids() {
  if command -v pidof >/dev/null 2>&1; then
    pidof "$PID_NAME" 2>/dev/null || true
  elif command -v pgrep >/dev/null 2>&1; then
    pgrep -x "$PID_NAME" 2>/dev/null || true
  else
    printf '\n'
  fi
}

is_service_active() {
  local pids

  case "$SERVICE_MANAGER" in
    systemd)
      systemctl is-active --quiet "$SERVICE_NAME"
      ;;
    initd)
      if [ ! -x "$INIT_SCRIPT" ]; then
        return 1
      fi
      if "$INIT_SCRIPT" status >/dev/null 2>&1; then
        return 0
      fi
      if "$INIT_SCRIPT" running >/dev/null 2>&1; then
        return 0
      fi
      pids="$(service_pids)"
      [ -n "$pids" ]
      ;;
  esac
}

wait_for_systemd_service_active() {
  local baseline_restarts="${1:-}"
  local deadline
  local state
  local current_restarts

  deadline=$(($(date +%s) + VERIFY_SECONDS))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
    case "$state" in
      active|activating)
        ;;
      *)
        log "service state is not healthy: ${state:-unknown}"
        return 1
        ;;
    esac

    current_restarts="$(service_restart_count)"
    if is_number "$baseline_restarts" && is_number "$current_restarts"; then
      if [ "$current_restarts" -gt "$baseline_restarts" ]; then
        log "service restarted unexpectedly during verification: $baseline_restarts -> $current_restarts"
        return 1
      fi
    fi

    sleep 1
  done

  systemctl is-active --quiet "$SERVICE_NAME"
}

wait_for_initd_service_active() {
  local deadline
  local first_pids
  local current_pids

  deadline=$(($(date +%s) + VERIFY_SECONDS))
  first_pids=""

  while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! is_service_active; then
      log "service is not running according to init.d: $SERVICE_NAME"
      return 1
    fi

    current_pids="$(service_pids)"
    if [ -n "$current_pids" ]; then
      if [ -z "$first_pids" ]; then
        first_pids="$current_pids"
      elif [ "$current_pids" != "$first_pids" ]; then
        log "service process changed during verification: $first_pids -> $current_pids"
        return 1
      fi
    fi

    sleep 1
  done

  is_service_active
}

wait_for_service_active() {
  local baseline_restarts="${1:-}"

  case "$SERVICE_MANAGER" in
    systemd) wait_for_systemd_service_active "$baseline_restarts" ;;
    initd) wait_for_initd_service_active ;;
  esac
}

log_recent_service_logs() {
  case "$SERVICE_MANAGER" in
    systemd)
      log "recent ${SERVICE_NAME} journal:"
      journalctl -u "$SERVICE_NAME" -n "$LOG_LINES" --no-pager -o short-iso || true
      ;;
    initd)
      if command -v logread >/dev/null 2>&1; then
        log "recent ${SERVICE_NAME} logread lines:"
        logread | grep -i "$SERVICE_NAME" | tail -n "$LOG_LINES" || true
      else
        log "logread is unavailable; skip recent service logs"
      fi
      ;;
  esac
}

install_package() {
  local package_path="$1"

  log "installing package: $package_path"
  case "$PACKAGE_MANAGER" in
    deb) dpkg -i "$package_path" ;;
    apk) apk add --allow-untrusted "$package_path" ;;
  esac
}

restart_service() {
  case "$SERVICE_MANAGER" in
    systemd)
      systemctl daemon-reload && systemctl restart "$SERVICE_NAME"
      ;;
    initd)
      "$INIT_SCRIPT" restart
      ;;
  esac
}

rollback() {
  local reason="$1"
  local rollback_message

  log "update failed: $reason"
  log_recent_service_logs

  if [ -z "$ROLLBACK_PACKAGE" ] || [ ! -s "$ROLLBACK_PACKAGE" ]; then
    die "rollback package is unavailable"
  fi

  log "rolling back to sing-box $CURRENT_VERSION"
  if ! install_package "$ROLLBACK_PACKAGE"; then
    log "ERROR: rollback package installation failed"
    log_recent_service_logs
    exit 1
  fi

  if ! restart_service; then
    log "ERROR: rollback service restart failed"
    log_recent_service_logs
    exit 1
  fi

  if ! wait_for_service_active; then
    log "ERROR: rollback service verification failed"
    log_recent_service_logs
    exit 1
  fi

  rollback_message="rolled back to sing-box $CURRENT_VERSION after failed update to $LATEST_VERSION"
  log "$rollback_message"
  exit "$ROLLBACK_EXIT_CODE"
}

main() {
  local latest_package
  local baseline_restarts

  parse_args "$@"

  require_root
  setup_logging
  acquire_lock

  require_command awk
  require_command curl
  require_command date
  require_command grep
  require_command tail

  detect_runtime

  case "$PACKAGE_MANAGER" in
    deb)
      require_command dpkg
      require_command dpkg-deb
      require_command dpkg-query
      ;;
    apk)
      require_command apk
      ;;
  esac

  case "$SERVICE_MANAGER" in
    systemd)
      require_command systemctl
      require_command journalctl
      ;;
    initd)
      [ -x "$INIT_SCRIPT" ] || die "init script is not executable: $INIT_SCRIPT"
      ;;
  esac

  detect_arch
  detect_sing_box_binary
  ensure_package_installed
  detect_current_version

  log "current sing-box version: $CURRENT_VERSION"

  if [ "$FORCE_INSTALL" = "1" ]; then
    if [ -z "$FORCE_VERSION" ]; then
      die "force version is empty"
    fi

    log "force install requested: $FORCE_VERSION"
    latest_package="$(ensure_cached_package "$FORCE_VERSION")" ||
      die "failed to download forced package: $FORCE_VERSION"

    if ! install_package "$latest_package"; then
      die "package manager failed while force installing $FORCE_VERSION"
    fi

    log "force install completed: $CURRENT_VERSION -> $FORCE_VERSION"
    log "service was not restarted; update configuration and restart $SERVICE_NAME manually"
    exit 0
  fi

  if ! is_service_active; then
    die "service is not active before update; refusing to touch installed package: $SERVICE_NAME"
  fi

  log "checking current configuration with current binary"
  if ! run_config_check; then
    die "current configuration does not pass validation with current binary; aborting before update"
  fi

  if ! fetch_latest_beta_version; then
    die "failed to find a prerelease version from ${RELEASE_REPO}"
  fi

  log "latest beta version: $LATEST_VERSION"

  if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    log "already on latest beta; no update needed"
    exit 0
  fi

  ensure_not_downgrade

  log "caching rollback package for current version"
  ROLLBACK_PACKAGE="$(ensure_cached_package "$CURRENT_VERSION")" ||
    die "failed to cache rollback package for current version: $CURRENT_VERSION"

  latest_package="$(ensure_cached_package "$LATEST_VERSION")" ||
    die "failed to download latest beta package: $LATEST_VERSION"

  if ! install_package "$latest_package"; then
    rollback "package manager failed while installing $LATEST_VERSION"
  fi

  detect_sing_box_binary
  log "checking configuration with new binary"
  if ! run_config_check; then
    rollback "configuration check failed with $LATEST_VERSION"
  fi

  baseline_restarts="$(service_restart_count)"
  log "restarting service and observing for ${VERIFY_SECONDS}s"
  if ! restart_service; then
    rollback "service restart failed after installing $LATEST_VERSION"
  fi

  if ! wait_for_service_active "$baseline_restarts"; then
    rollback "service did not stay active after installing $LATEST_VERSION"
  fi

  log "updated sing-box successfully: $CURRENT_VERSION -> $LATEST_VERSION"
}

main "$@"
