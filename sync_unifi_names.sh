#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/unifi_routeros_sync.conf"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_GREEN=""
  C_RED=""
  C_YELLOW=""
  C_BLUE=""
fi

log_section() {
  printf '\n%s== %s ==%s\n' "$C_BOLD$C_BLUE" "$1" "$C_RESET" >&2
}

log_info() {
  printf '%s•%s %s\n' "$C_BLUE" "$C_RESET" "$1" >&2
}

log_success() {
  printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1" >&2
}

log_warn() {
  printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2
}

log_error() {
  printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$1" >&2
}

# 计算字符串在终端中的显示宽度：ASCII 按 1 列，常见中文按 2 列近似处理。
display_width() {
  local text="$1"
  local char_len byte_len
  char_len=${#text}
  byte_len=$(LC_ALL=C; printf '%s' "$text" | wc -c | tr -d ' ')
  printf '%d\n' $((char_len + (byte_len - char_len) / 2))
}

# 按显示宽度右侧补空格，避免中文字符导致 printf 宽度错位。
pad_right() {
  local text="$1"
  local target_width="$2"
  local width pad
  width=$(display_width "$text")
  pad=$((target_width - width))
  (( pad < 0 )) && pad=0
  printf '%s%*s' "$text" "$pad" ''
}

# 打印两列键值摘要。
print_kv() {
  printf '  %s%s%s %s\n' "$C_DIM" "$(pad_right "$1" 20)" "$C_RESET" "$2" >&2
}

# 打印预览表格中的“旧名称 -> 新名称”。
print_plan_update_row() {
  local mac="$1" old_name="$2" new_name="$3"
  printf '  %s  %s ->  %s\n' "$(pad_right "$mac" 17)" "$(pad_right "$old_name" 34)" "$new_name" >&2
}

# 打印 UniFi 未找到的客户端。
print_plan_missing_row() {
  local mac="$1" name="$2"
  printf '  %s  %s\n' "$(pad_right "$mac" 17)" "$name" >&2
}

# 打印导入进度，结果列固定在同一位置。
print_import_prefix() {
  local mac="$1" name="$2"
  printf '  %s  %s  ...... ' "$(pad_right "$mac" 17)" "$(pad_right "$name" 34)" >&2
}

curl_hint() {
  local target="$1"
  local detail="$2"

  if grep -qiE 'Failed to connect|Could not connect|Connection refused|Connection timed out|No route to host|Network is unreachable' <<<"$detail"; then
    cat <<EOF_HINT
  提示：这是 TCP 连接失败，通常不是用户名或密码错误。
  请先在运行脚本的 Debian 机器上测试：curl -kI ${target}
  重点检查 IP、端口、VLAN/防火墙、Cloud Key 是否开机，以及 Web 管理页面是否就是这个地址和端口。
EOF_HINT
  elif grep -qiE 'SSL certificate|self signed|certificate' <<<"$detail"; then
    cat <<'EOF_HINT'
  提示：这是 SSL 证书校验问题。Cloud Key 使用自签证书时，可在配置里设置 UniFiVerifySSL false。
EOF_HINT
  elif grep -qiE '401|403|Unauthorized|Forbidden' <<<"$detail"; then
    cat <<'EOF_HINT'
  提示：这是认证或权限问题。请检查用户名/密码，并确认该账号有 UniFi Network 管理权限。
EOF_HINT
  fi
}

usage() {
  cat <<'USAGE'
Usage:
  sync_unifi_names.sh [--config PATH] [--routeros-password PASSWORD] [--unifi-password PASSWORD]

Silent mode:
  Provide --config plus both passwords, or put RouterOSPassword and UniFiPassword in the config file
  and run with --config only.

Interactive mode:
  Without complete passwords, the script reads the key-value config as defaults, prompts step by step,
  saves non-password config, previews changes, then asks "是否执行同步? [y/N]:" before writing.
USAGE
}

CONFIG_ARG=""
ROUTEROS_PASSWORD_ARG=""
UNIFI_PASSWORD_ARG=""
UNIFI_CSRF_TOKEN=""
COOKIE_FILE=""

# 清理 UniFi 登录 Cookie，避免 EXIT trap 引用 main 的局部变量。
cleanup() {
  [[ -n "${COOKIE_FILE:-}" ]] && rm -f "$COOKIE_FILE"
  return 0
}
trap cleanup EXIT

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

CONFIG_PATH="${CONFIG_ARG:-$DEFAULT_CONFIG}"
ROUTEROS_PASSWORD="$ROUTEROS_PASSWORD_ARG"
UNIFI_PASSWORD="$UNIFI_PASSWORD_ARG"

if [[ -n "$CONFIG_ARG" && -n "$ROUTEROS_PASSWORD_ARG" && -n "$UNIFI_PASSWORD_ARG" ]]; then
  SILENT=1
else
  SILENT=0
fi

# 检查运行所需的外部命令。
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    echo "On Debian, install dependencies with: sudo apt-get install curl jq" >&2
    exit 1
  }
}

# 从“键 值”配置文件读取配置，缺失时使用默认值。
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

# 只保存非敏感配置，密码始终由交互或命令行提供。
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
  log_error "$msg"
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
  [[ -z "$ROUTEROS_PASSWORD" ]] && ROUTEROS_PASSWORD="$(config_get "$CONFIG_PATH" 'RouterOSPassword' '')"

  UNIFI_HOST="$(config_get "$CONFIG_PATH" 'CloudKeyIP' '192.168.88.2')"
  UNIFI_PORT="$(config_get "$CONFIG_PATH" 'CloudKeyPort' '443')"
  UNIFI_USERNAME="$(config_get "$CONFIG_PATH" 'UniFiUser' 'admin')"
  [[ -z "$UNIFI_PASSWORD" ]] && UNIFI_PASSWORD="$(config_get "$CONFIG_PATH" 'UniFiPassword' '')"
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
  log_success "配置已保存到 $CONFIG_PATH，密码未保存。"
}

# 读取 RouterOS 静态 DHCP 租约，并只保留带注释的 MAC/名称。
fetch_routeros_leases() {
  local insecure=()
  [[ "$ROUTEROS_SCHEME" == "https" ]] && insecure=(-k)
  curl -fsS "${insecure[@]}" \
    -u "${ROUTEROS_USERNAME}:${ROUTEROS_PASSWORD}" \
    "${ROUTEROS_SCHEME}://${ROUTEROS_HOST}:${ROUTEROS_PORT}/rest/ip/dhcp-server/lease" \
    | jq 'map(select(((.dynamic // "false") | tostring) == "false") | select((.comment // "") != "") | {mac: ((."mac-address" // "") | ascii_downcase), name: (.comment | tostring)}) | map(select(.mac != "")) | unique_by(.mac)'
}

# 登录 UniFi OS，保存 Cookie，并尽量提取写入接口需要的 CSRF token。
unifi_login() {
  local cookie_file="$1"
  local insecure=()
  [[ "$UNIFI_VERIFY_SSL" == "false" ]] && insecure=(-k)
  local payload header_file
  payload="$(jq -n --arg username "$UNIFI_USERNAME" --arg password "$UNIFI_PASSWORD" '{username:$username,password:$password,remember:false}')"
  header_file="$(mktemp)"

  curl -fsS "${insecure[@]}" \
    -c "$cookie_file" -b "$cookie_file" \
    -D "$header_file" \
    -H 'Content-Type: application/json' \
    -H 'X-Requested-With: XMLHttpRequest' \
    -X POST \
    --data "$payload" \
    "https://${UNIFI_HOST}:${UNIFI_PORT}/api/auth/login" >/dev/null \
    || {
      rm -f "$header_file"
      return 1
    }

  UNIFI_CSRF_TOKEN="$(awk 'tolower($1) == "x-csrf-token:" {sub(/\r$/, "", $2); print $2; exit}' "$header_file")"
  rm -f "$header_file"
}

# 合并 UniFi 当前在线客户端和历史客户端，生成按 MAC 去重的客户端表。
fetch_unifi_clients() {
  local cookie_file="$1"
  local insecure=()
  [[ "$UNIFI_VERIFY_SSL" == "false" ]] && insecure=(-k)
  local base="https://${UNIFI_HOST}:${UNIFI_PORT}/proxy/network/api/s/${UNIFI_SITE}"
  local tmp_sta tmp_user
  tmp_sta="$(mktemp)"
  tmp_user="$(mktemp)"

  local sta_ok=1 user_ok=1
  if ! curl -fsS "${insecure[@]}" -c "$cookie_file" -b "$cookie_file" "$base/stat/sta" > "$tmp_sta"; then
    echo '{"data":[]}' > "$tmp_sta"
    sta_ok=0
  fi
  if ! curl -fsS "${insecure[@]}" -c "$cookie_file" -b "$cookie_file" "$base/rest/user" > "$tmp_user"; then
    echo '{"data":[]}' > "$tmp_user"
    user_ok=0
  fi

  if [[ "$sta_ok" -eq 0 && "$user_ok" -eq 0 ]]; then
    rm -f "$tmp_sta" "$tmp_user"
    return 1
  fi

  jq -s '[.[0].data[]?, .[1].data[]?] | map(select(.mac != null and ._id != null) | {mac:(.mac|ascii_downcase), id:._id, name:(.name // .hostname // "")}) | unique_by(.mac)' "$tmp_sta" "$tmp_user"
  rm -f "$tmp_sta" "$tmp_user"
}

# 对比 RouterOS 注释和 UniFi 名称，生成更新/一致/缺失三类计划。
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

# 将单个客户端名称写回 UniFi。
update_unifi_client() {
  local cookie_file="$1"
  local client_id="$2"
  local name="$3"
  local insecure=()
  [[ "$UNIFI_VERIFY_SSL" == "false" ]] && insecure=(-k)
  local payload base
  payload="$(jq -n --arg name "$name" '{name:$name}')"
  base="https://${UNIFI_HOST}:${UNIFI_PORT}/proxy/network/api/s/${UNIFI_SITE}"

  local headers=(-H 'Content-Type: application/json' -H 'X-Requested-With: XMLHttpRequest')
  [[ -n "$UNIFI_CSRF_TOKEN" ]] && headers+=(-H "X-CSRF-Token: ${UNIFI_CSRF_TOKEN}")

  curl -fsS "${insecure[@]}" \
    -c "$cookie_file" -b "$cookie_file" \
    "${headers[@]}" \
    -X PUT \
    --data "$payload" \
    "$base/rest/user/${client_id}" >/dev/null
}

main() {
  require_cmd curl
  require_cmd jq

  # 如果指定的配置文件里已经写了两个密码，也可以直接静默运行。
  if [[ "$SILENT" -eq 0 && -n "$CONFIG_ARG" && -f "$CONFIG_PATH" ]]; then
    load_config_values
    if [[ -n "$ROUTEROS_PASSWORD" && -n "$UNIFI_PASSWORD" ]]; then
      SILENT=1
    fi
  fi

  log_section "启动"
  if [[ "$SILENT" -eq 1 ]]; then
    load_config_values
    log_info "运行模式：静默模式"
  else
    interactive_config
    log_info "运行模式：交互模式"
  fi
  print_kv "配置文件" "$CONFIG_PATH"
  print_kv "RouterOS" "${ROUTEROS_SCHEME}://${ROUTEROS_HOST}:${ROUTEROS_PORT} (${ROUTEROS_USERNAME})"
  print_kv "Cloud Key" "https://${UNIFI_HOST}:${UNIFI_PORT} (${UNIFI_USERNAME}, site=${UNIFI_SITE})"

  local leases clients plan err_file
  err_file="$(mktemp)"

  log_section "连接 RouterOS"
  log_info "正在读取 DHCP 静态租约注释..."
  if leases="$(fetch_routeros_leases 2>"$err_file")"; then
    :
  else
    local reason
    reason="$(sed 's/^/  /' "$err_file")"
    rm -f "$err_file"
    local hint
    hint="$(curl_hint "${ROUTEROS_SCHEME}://${ROUTEROS_HOST}:${ROUTEROS_PORT}/" "$reason")"
    curl_fail "读取 RouterOS DHCP leases 失败。请确认地址、端口、协议、用户名/密码，以及 RouterOS v7 REST API 和 www/www-ssl 服务。${reason:+
$reason}${hint:+
$hint}"
  fi
  rm -f "$err_file"
  local lease_count
  lease_count="$(jq 'length' <<<"$leases")"
  log_success "RouterOS 连接成功，获取到 ${lease_count} 条 static 且带注释的 lease。"

  COOKIE_FILE="$(mktemp)"

  log_section "连接 Cloud Key"
  log_info "正在登录 UniFi OS..."
  err_file="$(mktemp)"
  if unifi_login "$COOKIE_FILE" 2>"$err_file"; then
    log_success "Cloud Key 登录成功。"
    if [[ -n "$UNIFI_CSRF_TOKEN" ]]; then
      log_success "已获取 UniFi 写入所需的 CSRF token。"
    else
      log_warn "登录响应里没有 CSRF token；如果写入返回 403，请确认 UniFi OS/API 版本。"
    fi
  else
    local reason
    reason="$(sed 's/^/  /' "$err_file")"
    rm -f "$err_file"
    local hint
    hint="$(curl_hint "https://${UNIFI_HOST}:${UNIFI_PORT}/" "$reason")"
    curl_fail "UniFi 登录失败。请确认 Cloud Key 地址、用户名、密码和 SSL 设置。${reason:+
$reason}${hint:+
$hint}"
  fi
  rm -f "$err_file"

  log_info "正在读取 UniFi active/known clients..."
  err_file="$(mktemp)"
  if clients="$(fetch_unifi_clients "$COOKIE_FILE" 2>"$err_file")"; then
    :
  else
    local reason
    reason="$(sed 's/^/  /' "$err_file")"
    rm -f "$err_file"
    local hint
    hint="$(curl_hint "https://${UNIFI_HOST}:${UNIFI_PORT}/proxy/network/" "$reason")"
    curl_fail "读取 UniFi clients 失败。请确认 site 名称是否为 '${UNIFI_SITE}'，以及账号是否有 Network 权限。${reason:+
$reason}${hint:+
$hint}"
  fi
  rm -f "$err_file"
  local client_count
  client_count="$(jq 'length' <<<"$clients")"
  log_success "Cloud Key 读取成功，获取到 ${client_count} 个 UniFi 已知客户端。"

  log_section "生成同步计划"
  plan="$(build_plan "$leases" "$clients")"

  local update_count unchanged_count missing_count failed_count=0 success_count=0
  update_count="$(jq '.update | length' <<<"$plan")"
  unchanged_count="$(jq '.unchanged | length' <<<"$plan")"
  missing_count="$(jq '.missing | length' <<<"$plan")"
  print_kv "准备更新" "$update_count"
  print_kv "名称已一致" "$unchanged_count"
  print_kv "UniFi 暂未找到" "$missing_count"

  if [[ "$SILENT" -eq 0 ]]; then
    if [[ "$update_count" -gt 0 ]]; then
      log_section "准备更新的客户端"
      while IFS=$'\t' read -r mac old_name name; do
        print_plan_update_row "$mac" "$old_name" "$name"
      done < <(jq -r '.update[] | [.mac, (.old_name // ""), .name] | @tsv' <<<"$plan")
    fi
    if [[ "$missing_count" -gt 0 ]]; then
      log_section "UniFi 暂未找到，跳过"
      while IFS=$'\t' read -r mac name; do
        print_plan_missing_row "$mac" "$name"
      done < <(jq -r '.missing[] | [.mac, .name] | @tsv' <<<"$plan")
    fi
    local confirm
    read -r -p '是否执行同步? [y/N]: ' confirm
    case "${confirm,,}" in
      y|yes) ;;
      *) log_warn "已取消，未写入 UniFi。"; exit 0 ;;
    esac
  fi

  log_section "导入到 Cloud Key"
  if [[ "$update_count" -eq 0 ]]; then
    log_success "没有需要更新的客户端。"
  fi
  while IFS=$'\t' read -r client_id mac name; do
    [[ -n "$client_id" ]] || continue
    print_import_prefix "$mac" "$name"
    err_file="$(mktemp)"
    if update_unifi_client "$COOKIE_FILE" "$client_id" "$name" 2>"$err_file"; then
      success_count=$((success_count + 1))
      printf '%ssuccess%s\n' "$C_GREEN" "$C_RESET" >&2
    else
      failed_count=$((failed_count + 1))
      printf '%sfailed%s\n' "$C_RED" "$C_RESET" >&2
      sed 's/^/    reason: /' "$err_file" >&2
      if grep -q '403' "$err_file"; then
        if [[ -n "$UNIFI_CSRF_TOKEN" ]]; then
          echo "    hint: UniFi 返回 403。脚本已带 CSRF token，请检查该账号是否有 Network 客户端写入权限。" >&2
        else
          echo "    hint: UniFi 返回 403，且登录响应未提供 CSRF token；请确认 Cloud Key / UniFi OS 版本或账号类型。" >&2
        fi
      fi
    fi
    rm -f "$err_file"
  done < <(jq -r '.update[] | [.id, .mac, .name] | @tsv' <<<"$plan")

  log_section "完成"
  print_kv "RouterOS leases" "$lease_count"
  print_kv "UniFi clients" "$client_count"
  print_kv "更新成功" "$success_count"
  print_kv "名称已一致" "$unchanged_count"
  print_kv "UniFi 未找到" "$missing_count"
  print_kv "失败" "$failed_count"

  if [[ "$failed_count" -gt 0 ]]; then
    exit 2
  fi
}

main "$@"
