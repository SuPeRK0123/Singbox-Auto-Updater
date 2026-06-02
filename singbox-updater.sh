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
