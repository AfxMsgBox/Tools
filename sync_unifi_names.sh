#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/unifi_routeros_sync.conf"

usage() {
  cat <<'USAGE'
Usage:
  sync_unifi_names.sh [--config PATH] [--routeros-password PASSWORD] [--unifi-password PASSWORD]

Silent mode:
  If and only if all three arguments are provided, the script runs non-interactively.

Interactive mode:
  If any of the three arguments is missing, the script reads the default key-value config as defaults,
  prompts step by step, saves the config without passwords, previews changes, then asks "是否执行同步? [y/N]:" before writing.
USAGE
}

CONFIG_ARG=""
ROUTEROS_PASSWORD_ARG=""
UNIFI_PASSWORD_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { echo "Missing value for --config" >&2; exit 1; }
      CONFIG_ARG="$2"
      shift 2
      ;;
    --routeros-password)
      [[ $# -ge 2 ]] || { echo "Missing value for --routeros-password" >&2; exit 1; }
      ROUTEROS_PASSWORD_ARG="$2"
      shift 2
      ;;
    --unifi-password)
      [[ $# -ge 2 ]] || { echo "Missing value for --unifi-password" >&2; exit 1; }
      UNIFI_PASSWORD_ARG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unsupported argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$CONFIG_ARG" && -n "$ROUTEROS_PASSWORD_ARG" && -n "$UNIFI_PASSWORD_ARG" ]]; then
  SILENT=1
  CONFIG_PATH="$CONFIG_ARG"
  ROUTEROS_PASSWORD="$ROUTEROS_PASSWORD_ARG"
  UNIFI_PASSWORD="$UNIFI_PASSWORD_ARG"
else
  SILENT=0
  CONFIG_PATH="${CONFIG_ARG:-$DEFAULT_CONFIG}"
  ROUTEROS_PASSWORD=""
  UNIFI_PASSWORD=""
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    echo "On Debian, install dependencies with: sudo apt-get install curl jq" >&2
    exit 1
  }
}

config_get() {
  local file="$1"
  local key="$2"
  local fallback="$3"
  local value
  if [[ -f "$file" ]]; then
    value="$(awk -v wanted="$key" '
      $0 ~ /^[[:space:]]*($|#)/ { next }
      $1 == wanted {
        $1=""
        sub(/^[[:space:]]+/, "")
        print
        found=1
        exit
      }
      END { if (!found) exit 1 }
    ' "$file" 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
      printf '%s\n' "$value"
      return
    fi
  fi
  printf '%s\n' "$fallback"
}

prompt_default() {
  local label="$1"
  local default="$2"
  local value
  read -r -p "$label [$default]: " value
  printf '%s\n' "${value:-$default}"
}

prompt_secret() {
  local label="$1"
  local value
  read -r -s -p "$label: " value
  printf '\n' >&2
  printf '%s\n' "$value"
}

normalize_bool_verify_ssl() {
  local skip_ssl="$1"
  case "${skip_ssl,,}" in
    y|yes|true|1|是|对) printf 'false\n' ;;
    n|no|false|0|否|不) printf 'true\n' ;;
    *) printf 'false\n' ;;
  esac
}

save_config() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF_CONFIG
RouterOSIP $ROUTEROS_HOST
RouterOSPort $ROUTEROS_PORT
RouterOSScheme $ROUTEROS_SCHEME
RouterOSUser $ROUTEROS_USERNAME
CloudKeyIP $UNIFI_HOST
CloudKeyPort $UNIFI_PORT
UniFiUser $UNIFI_USERNAME
UniFiSite $UNIFI_SITE
UniFiVerifySSL $UNIFI_VERIFY_SSL
EOF_CONFIG
  chmod 600 "$path" 2>/dev/null || true
}

curl_fail() {
  local msg="$1"
  echo "$msg" >&2
  exit 1
}

load_config_values() {
  [[ -f "$CONFIG_PATH" ]] || {
    if [[ "$SILENT" -eq 1 ]]; then
      echo "Config file not found: $CONFIG_PATH" >&2
      exit 1
    fi
  }

  ROUTEROS_HOST="$(config_get "$CONFIG_PATH" 'RouterOSIP' '192.168.88.1')"
  ROUTEROS_PORT="$(config_get "$CONFIG_PATH" 'RouterOSPort' '443')"
  ROUTEROS_SCHEME="$(config_get "$CONFIG_PATH" 'RouterOSScheme' 'https')"
  ROUTEROS_USERNAME="$(config_get "$CONFIG_PATH" 'RouterOSUser' 'admin')"

  UNIFI_HOST="$(config_get "$CONFIG_PATH" 'CloudKeyIP' '192.168.88.2')"
  UNIFI_PORT="$(config_get "$CONFIG_PATH" 'CloudKeyPort' '443')"
  UNIFI_USERNAME="$(config_get "$CONFIG_PATH" 'UniFiUser' 'admin')"
  UNIFI_SITE="$(config_get "$CONFIG_PATH" 'UniFiSite' 'default')"
  UNIFI_VERIFY_SSL="$(config_get "$CONFIG_PATH" 'UniFiVerifySSL' 'false')"
}

interactive_config() {
  local default_config="$CONFIG_PATH"
  CONFIG_PATH="$(prompt_default '配置文件路径' "$default_config")"
  load_config_values

  ROUTEROS_HOST="$(prompt_default 'RouterOS 地址' "$ROUTEROS_HOST")"
  ROUTEROS_SCHEME="$(prompt_default 'RouterOS REST 协议 http/https' "$ROUTEROS_SCHEME")"
  ROUTEROS_PORT="$(prompt_default 'RouterOS REST 端口' "$ROUTEROS_PORT")"
  ROUTEROS_USERNAME="$(prompt_default 'RouterOS 用户名' "$ROUTEROS_USERNAME")"
  ROUTEROS_PASSWORD="$(prompt_secret 'RouterOS 密码')"

  UNIFI_HOST="$(prompt_default 'Cloud Key 地址' "$UNIFI_HOST")"
  UNIFI_PORT="$(prompt_default 'Cloud Key HTTPS 端口' "$UNIFI_PORT")"
  UNIFI_USERNAME="$(prompt_default 'UniFi 用户名' "$UNIFI_USERNAME")"
  UNIFI_PASSWORD="$(prompt_secret 'UniFi 密码')"
  UNIFI_SITE="$(prompt_default 'UniFi site' "$UNIFI_SITE")"

  local skip_default="Y"
  [[ "$UNIFI_VERIFY_SSL" == "true" ]] && skip_default="N"
  local skip_ssl
  skip_ssl="$(prompt_default '跳过 Cloud Key SSL 证书校验? Y/N' "$skip_default")"
  UNIFI_VERIFY_SSL="$(normalize_bool_verify_ssl "$skip_ssl")"

  save_config "$CONFIG_PATH"
  echo "配置已保存到 $CONFIG_PATH，密码未保存。"
}

fetch_routeros_leases() {
  local insecure=()
  [[ "$ROUTEROS_SCHEME" == "https" ]] && insecure=(-k)
  curl -fsS "${insecure[@]}" \
    -u "${ROUTEROS_USERNAME}:${ROUTEROS_PASSWORD}" \
    "${ROUTEROS_SCHEME}://${ROUTEROS_HOST}:${ROUTEROS_PORT}/rest/ip/dhcp-server/lease" \
    | jq 'map(select(((.dynamic // "false") | tostring) == "false") | select((.comment // "") != "") | {mac: ((."mac-address" // "") | ascii_downcase), name: (.comment | tostring)}) | map(select(.mac != "")) | unique_by(.mac)'
}

unifi_login() {
  local cookie_file="$1"
  local insecure=()
  [[ "$UNIFI_VERIFY_SSL" == "false" ]] && insecure=(-k)
  local payload
  payload="$(jq -n --arg username "$UNIFI_USERNAME" --arg password "$UNIFI_PASSWORD" '{username:$username,password:$password,remember:false}')"

  curl -fsS "${insecure[@]}" \
    -c "$cookie_file" -b "$cookie_file" \
    -H 'Content-Type: application/json' \
    -X POST \
    --data "$payload" \
    "https://${UNIFI_HOST}:${UNIFI_PORT}/api/auth/login" >/dev/null \
    || curl_fail "UniFi login failed. Check Cloud Key address, username, password, and SSL settings."
}

fetch_unifi_clients() {
  local cookie_file="$1"
  local insecure=()
  [[ "$UNIFI_VERIFY_SSL" == "false" ]] && insecure=(-k)
  local base="https://${UNIFI_HOST}:${UNIFI_PORT}/proxy/network/api/s/${UNIFI_SITE}"
  local tmp_sta tmp_user
  tmp_sta="$(mktemp)"
  tmp_user="$(mktemp)"

  if ! curl -fsS "${insecure[@]}" -c "$cookie_file" -b "$cookie_file" "$base/stat/sta" > "$tmp_sta"; then
    echo '{"data":[]}' > "$tmp_sta"
  fi
  if ! curl -fsS "${insecure[@]}" -c "$cookie_file" -b "$cookie_file" "$base/rest/user" > "$tmp_user"; then
    echo '{"data":[]}' > "$tmp_user"
  fi

  jq -s '[.[0].data[]?, .[1].data[]?] | map(select(.mac != null and ._id != null) | {mac:(.mac|ascii_downcase), id:._id, name:(.name // .hostname // "")}) | unique_by(.mac)' "$tmp_sta" "$tmp_user"
  rm -f "$tmp_sta" "$tmp_user"
}

build_plan() {
  local leases_json="$1"
  local clients_json="$2"
  jq -n --argjson leases "$leases_json" --argjson clients "$clients_json" '
    def bymac($items): reduce $items[] as $item ({}; .[$item.mac] = $item);
    (bymac($clients)) as $client_map |
    {
      update: [$leases[] | . as $lease | $client_map[$lease.mac] as $client | select($client != null) | select(($client.name // "") != $lease.name) | {mac:$lease.mac, id:$client.id, old_name:($client.name // ""), name:$lease.name}],
      unchanged: [$leases[] | . as $lease | $client_map[$lease.mac] as $client | select($client != null) | select(($client.name // "") == $lease.name) | {mac:$lease.mac, name:$lease.name}],
      missing: [$leases[] | . as $lease | select($client_map[$lease.mac] == null) | {mac:$lease.mac, name:$lease.name}]
    }'
}

update_unifi_client() {
  local cookie_file="$1"
  local client_id="$2"
  local name="$3"
  local insecure=()
  [[ "$UNIFI_VERIFY_SSL" == "false" ]] && insecure=(-k)
  local payload base
  payload="$(jq -n --arg name "$name" '{name:$name}')"
  base="https://${UNIFI_HOST}:${UNIFI_PORT}/proxy/network/api/s/${UNIFI_SITE}"

  curl -fsS "${insecure[@]}" \
    -c "$cookie_file" -b "$cookie_file" \
    -H 'Content-Type: application/json' \
    -X PUT \
    --data "$payload" \
    "$base/rest/user/${client_id}" >/dev/null
}

main() {
  require_cmd curl
  require_cmd jq

  if [[ "$SILENT" -eq 1 ]]; then
    load_config_values
  else
    interactive_config
  fi

  local leases clients plan cookie_file
  leases="$(fetch_routeros_leases)" || curl_fail "Failed to read RouterOS DHCP leases. RouterOS REST API requires RouterOS v7 and www/www-ssl service."
  cookie_file="$(mktemp)"
  trap 'rm -f "$cookie_file"' EXIT
  unifi_login "$cookie_file"
  clients="$(fetch_unifi_clients "$cookie_file")" || curl_fail "Failed to read UniFi clients."
  plan="$(build_plan "$leases" "$clients")"

  local lease_count client_count update_count unchanged_count missing_count failed_count=0 success_count=0
  lease_count="$(jq 'length' <<<"$leases")"
  client_count="$(jq 'length' <<<"$clients")"
  update_count="$(jq '.update | length' <<<"$plan")"
  unchanged_count="$(jq '.unchanged | length' <<<"$plan")"
  missing_count="$(jq '.missing | length' <<<"$plan")"

  if [[ "$SILENT" -eq 0 ]]; then
    echo
    echo "RouterOS static 且带注释的 lease: $lease_count"
    echo "UniFi 已知客户端: $client_count"
    echo "准备更新: $update_count"
    echo "名称已一致: $unchanged_count"
    echo "UniFi 暂未找到，跳过: $missing_count"
    echo
    if [[ "$update_count" -gt 0 ]]; then
      echo "准备更新的客户端："
      jq -r '.update[] | "  \(.mac): \(.old_name // "") -> \(.name)"' <<<"$plan"
      echo
    fi
    if [[ "$missing_count" -gt 0 ]]; then
      echo "UniFi 暂未找到的客户端："
      jq -r '.missing[] | "  \(.mac): \(.name)"' <<<"$plan"
      echo
    fi
    local confirm
    read -r -p '是否执行同步? [y/N]: ' confirm
    case "${confirm,,}" in
      y|yes) ;;
      *) echo "已取消，未写入 UniFi。"; exit 0 ;;
    esac
  fi

  while IFS=$'\t' read -r client_id mac name; do
    [[ -n "$client_id" ]] || continue
    if update_unifi_client "$cookie_file" "$client_id" "$name"; then
      success_count=$((success_count + 1))
      [[ "$SILENT" -eq 0 ]] && echo "[OK] $mac -> $name"
    else
      failed_count=$((failed_count + 1))
      echo "[FAIL] $mac -> $name" >&2
    fi
  done < <(jq -r '.update[] | [.id, .mac, .name] | @tsv' <<<"$plan")

  echo "完成：RouterOS=$lease_count, UniFi=$client_count, 更新成功=$success_count, 名称已一致=$unchanged_count, UniFi未找到=$missing_count, 失败=$failed_count"

  if [[ "$failed_count" -gt 0 ]]; then
    exit 2
  fi
}

main "$@"
