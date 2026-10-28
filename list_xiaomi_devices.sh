#!/usr/bin/env bash
# Bash 3.2+；只读 SSH 采集，jq 负责设备关联与 IPv4 数值排序。
set -euo pipefail

usage() {
  cat <<'USAGE'
用法：
  ./list_xiaomi_devices.sh --host HA地址 --user SSH用户名 [选项]
  ./list_xiaomi_devices.sh                 # 交互输入地址、用户名和可选密码

选项：
  --host ADDRESS       SSH 地址/IP/SSH 配置别名，不是 HA 网页 URL
  --user USER          SSH 用户名
  --password PASSWORD  可选；省略或空字符串时使用 SSH 密钥/agent
  --ask-password       隐藏输入密码，直接回车使用免密认证
  --port PORT          SSH 端口，默认遵循 SSH 配置（通常为 22）
  --identity FILE      SSH 私钥文件
  --config-dir DIR     远端 HA 配置目录，默认自动探测
  --format FORMAT      table（默认，对齐表格）或 tsv（导出）
  --cached-only        仅查缓存，不连接小米云端
  --no-color           禁用终端颜色，也可设置 NO_COLOR
  -h, --help           显示帮助

输出：按账号、家庭分组，显示名称、房间、设备类型、MAC、IP。
各家庭内 IPv4 按数值升序；蓝牙 IP、缺失字段为空。
默认通过 HA 已有授权只读查询小米云端，授权不会传回本机。
依赖：本机 bash、ssh、jq；远端 sh、jq、curl 及常见 GNU/BusyBox 工具。
非空密码额外需要本机 sshpass。首次连接请先用 ssh 确认服务器指纹。
USAGE
}

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
host='' ssh_user='' password='' port='' identity='' config_dir='' ask_password=0
format=table cached_only=0 no_color=0
# 无参数启动进入完整交互流程；密码可直接回车跳过。
if [[ $# -eq 0 ]]; then
  ask_password=1
fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host|--user|--password|--port|--identity|--config-dir|--format)
      [[ $# -ge 2 ]] || die "$1 缺少参数值"
      case "$1" in
        --host) host=$2 ;;
        --user) ssh_user=$2 ;;
        --password) password=$2 ;;
        --port) port=$2 ;;
        --identity) identity=$2 ;;
        --config-dir) config_dir=$2 ;;
        --format) format=$2 ;;
      esac
      shift 2 ;;
    --ask-password) ask_password=1; shift ;;
    --cached-only) cached_only=1; shift ;;
    --no-color) no_color=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（使用 --help 查看用法）" ;;
  esac
done
[[ "$format" == table || "$format" == tsv ]] || die '--format 仅支持 table 或 tsv'

if [[ -z "$host" ]]; then
  [[ -t 0 ]] || die '请通过 --host 指定 HA 服务器地址'
  read -r -p 'HA 服务器 SSH 地址：' host || die '未输入服务器地址'
fi
if [[ -z "$ssh_user" ]]; then
  [[ -t 0 ]] || die '请通过 --user 指定 SSH 用户名'
  read -r -p 'SSH 用户名：' ssh_user || die '未输入用户名'
fi
[[ "$host" =~ ^[a-zA-Z0-9_:][a-zA-Z0-9_.:%-]*$ ]] || die '地址必须是主机名、IP 或 SSH 别名，不能包含 URL、用户名或端口'
[[ "$ssh_user" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]*$ ]] || die 'SSH 用户名格式无效'
if [[ -n "$port" ]]; then
  [[ "$port" =~ ^[0-9]{1,5}$ ]] || die '端口必须为 1–65535'
  port=$((10#$port))
  (( port >= 1 && port <= 65535 )) || die '端口必须为 1–65535'
fi
[[ -z "$identity" || -r "$identity" ]] || die '无法读取私钥文件'
[[ -z "$config_dir" || "$config_dir" == /* ]] || die '--config-dir 必须为远端绝对路径'
if (( ask_password )); then
  [[ -t 0 ]] || die '--ask-password 需要交互终端'
  read -r -s -p 'SSH 密码（可留空）：' password || die '无法读取密码'
  printf '\n' >&2
fi
[[ "$password" != *$'\n'* && "$password" != *$'\r'* ]] || die '密码不能包含换行符'
for tool in ssh jq mktemp; do
  command -v "$tool" >/dev/null 2>&1 || die "本机缺少依赖：$tool"
done
if [[ -n "$password" ]]; then
  command -v sshpass >/dev/null 2>&1 || die '非空密码认证需要安装 sshpass；也可省略密码使用 SSH 密钥'
fi

# 单引号转义适用于远端 POSIX shell；不使用 eval 或 Bash 专属的 %q。
shell_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
ssh_args=(-T -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2)
[[ -z "$port" ]] || ssh_args+=(-p "$port")
[[ -z "$identity" ]] || ssh_args+=(-i "$identity")
if [[ -n "$password" ]]; then
  ssh_args+=(-o BatchMode=no -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1)
else
  ssh_args+=(-o BatchMode=yes)
fi
ssh_args+=(-l "$ssh_user" "$host" "sh -s -- $(shell_quote "$config_dir") $cached_only")
run_ssh() {
  if [[ -n "$password" ]]; then
    sshpass -d 3 ssh "${ssh_args[@]}" 3<<<"$password"
  else
    ssh "${ssh_args[@]}"
  fi
}

umask 077
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/ha-xiaomi.XXXXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 远端仅执行读取和投影；设备 token、账号认证文件均不会传回本机。
if ! run_ssh >"$work_dir/input.jsonl" <<'REMOTE'
set -eu
fail() { printf '远端错误：%s\n' "$*" >&2; exit 1; }
for tool in jq head wc tail od sha256sum tr; do
  command -v "$tool" >/dev/null 2>&1 || fail "缺少依赖 $tool"
done
config_dir=$1
cached_only=$2
if [ "$cached_only" -eq 0 ]; then
  command -v curl >/dev/null 2>&1 || fail '缺少 curl；可用 --cached-only 仅查缓存'
fi
# 所有 .dict 都先验证尾部 SHA-256；账号内容仅供远端 curl 使用。
read_storage() {
  file=$1
  label=$2
  [ -r "$file" ] || fail "$label 不存在或不可读"
  size=$(wc -c < "$file")
  [ "$size" -gt 32 ] || fail "$label 长度无效"
  size=$((size - 32))
  actual=$(head -c "$size" "$file" | sha256sum)
  actual=${actual%% *}
  expected=$(tail -c 32 "$file" | od -An -v -tx1 | tr -d ' \n')
  [ "$actual" = "$expected" ] || fail "$label 校验失败，可能正被更新，请重试"
  head -c "$size" "$file"
}
if [ -z "$config_dir" ]; then
  for candidate in /homeassistant /config /usr/share/hassio/homeassistant /var/lib/homeassistant /var/lib/homeassistant/.homeassistant "${HOME:-/root}/.homeassistant"; do
    if [ -r "$candidate/.storage/core.device_registry" ]; then
      config_dir=$candidate
      break
    fi
  done
fi
[ -n "$config_dir" ] || fail '未找到 HA 配置目录，请使用 --config-dir 指定'
registry=$config_dir/.storage/core.device_registry
[ -r "$registry" ] || fail '设备注册表不存在或不可读'
registry_json=$(jq -ce '
  if (.data.devices | type) != "array" then error("设备注册表格式无效") else
    {kind:"registry", devices:[.data.devices[] |
      select(any(.identifiers[]?; .[0] == "xiaomi_home")) |
      {id, name, name_by_user,
       entry_ids:([.config_entry_id?, .primary_config_entry?, .config_entries[]?] |
         map(select(type == "string" and length > 0)) | unique),
       identifiers:[.identifiers[] | select(.[0] == "xiaomi_home") | .[1]],
       macs:[.connections[]? | select(.[0] == "mac") | .[1]]}]}
  end' "$registry") || fail '无法解析设备注册表'
printf '%s\n' "$registry_json"

# 仅投影账号显示信息和关联 ID，不传输配置条目的其他内容。
entries=$config_dir/.storage/core.config_entries
[ -r "$entries" ] || fail '集成配置注册表不可读，无法可靠区分小米账号'
accounts_json=$(jq -ce '
  def first_label: map(select(type == "string" and length > 0)) | .[0] // "";
  if (.data.entries | type) != "array" then error("集成注册表格式无效") else
    {kind:"accounts", accounts:([.data.entries[] | select(.domain == "xiaomi_home") |
      {entry_id, uid:((.data.uid // "") | tostring), region:(.data.cloud_server // ""),
       name:([.data.nick_name, .title] | first_label)} |
      . + {key:(if .uid != "" and .region != "" then .uid + "_" + .region
                else "entry:" + .entry_id end)}] |
      group_by(.key) | map({key:.[0].key, uid:.[0].uid, region:.[0].region,
        name:.[0].name, entry_ids:map(.entry_id)}))}
  end' "$entries") || fail '无法解析小米账号信息'
printf '%s\n' "$accounts_json"

# 使用 SSH 所在网络命名空间中已有的 IPv4 邻居记录，不主动扫描。
neighbors=''
if command -v ip >/dev/null 2>&1; then
  neighbors=$(ip -4 neigh show 2>/dev/null) || neighbors=''
fi
printf '%s\n' "$neighbors" | jq -Rsc '
  {kind:"neighbors", rows:[split("\n")[] |
    select(test(" (FAILED|INCOMPLETE|NOARP)( |$)") | not) |
    try capture("^(?<ip>[0-9.]+) .*lladdr (?<mac>[0-9a-fA-F:]+) ") catch empty]}'

cache_count=0
for cache in "$config_dir"/.storage/xiaomi_home/miot_devices/*.dict; do
  [ -e "$cache" ] || continue
  filename=${cache##*/}
  account_key=${filename%.dict}
  account_meta=$(printf '%s' "$accounts_json" | jq -c --arg key "$account_key" \
    '[.accounts[] | select(.key == $key)] | .[0] // null')
  [ "$account_meta" != null ] || continue
  registry_for_account=$(printf '%s' "$registry_json" | jq -c --argjson account "$account_meta" '
    .devices |= map(select(any(.entry_ids[]; . as $id | $account.entry_ids | index($id))))')
  region=$account_key
  region=${region##*_}
  cache_data=$(read_storage "$cache" '设备缓存') || exit 1
  cache_json=$(printf '%s' "$cache_data" | jq -ce --arg region "$region" --arg account "$account_key" '
    def flatten_devices:
      . as $parent | ., ((.sub_devices // {})[] |
        . + {home_id:(.home_id // $parent.home_id), home_name:(.home_name // $parent.home_name),
             room_id:(.room_id // $parent.room_id), room_name:(.room_name // $parent.room_name)} |
        flatten_devices);
    if type != "object" then error("设备缓存格式无效") else
      {kind:"cache", account_key:$account, devices:[to_entries[] |
        (.value + {did:(.value.did // .key)}) | flatten_devices |
        {identifier: (($region + "_" + (.did | tostring)) |
          ascii_downcase | gsub("[^a-z0-9]+"; "_") | gsub("^_|_$"; "")),
         did:(.did | tostring), name, ip:(.localip // .local_ip // .ip), mac,
         home_id:((.home_id // "") | tostring), home_name, room_name, urn,
         pid:(.connect_type // .pid)}]}
    end') || fail '无法解析设备缓存'
  unset cache_data
  printf '%s\n' "$cache_json"
  cache_count=$((cache_count + 1))
  [ "$cached_only" -eq 0 ] || continue

  # 仅请求在 HA 注册表中出现的 DID，按 150 个分批并处理云端分页。
  dids=$(printf '%s' "$cache_json" | jq -c --argjson registry "$registry_for_account" '
    [$registry.devices[].identifiers[]] as $ids |
    [.devices[] | select(.identifier as $id | $ids | index($id)) | .did] | unique')
  count=$(printf '%s' "$dids" | jq 'length')
  [ "$count" -gt 0 ] || continue
  case "$region" in
    cn) api_host=ha.api.io.mi.com ;;
    de|i2|ru|sg|us) api_host=$region.ha.api.io.mi.com ;;
    *) fail '不支持的小米云地区，请检查缓存文件名' ;;
  esac
  account=$config_dir/.storage/xiaomi_home/miot_config/$filename
  account_data=$(read_storage "$account" '小米授权缓存') || exit 1
  auth_header=$(printf '%s' "$account_data" | jq -er '
    .auth_info.access_token | select(type == "string" and length > 0) |
    "header = " + ("Authorization: Bearer" + . | @json)') || fail '小米授权缺失，请在 HA 中重新登录小米 Home'
  unset account_data
  offset=0
  while [ "$offset" -lt "$count" ]; do
    batch=$(printf '%s' "$dids" | jq -c --argjson offset "$offset" '.[$offset:$offset+150]')
    cursor=''
    seen_cursors='[]'
    while :; do
      request=$(jq -cn --argjson dids "$batch" --arg cursor "$cursor" '
        {limit:200,get_split_device:true,get_third_device:true,dids:$dids} |
        if $cursor != "" then . + {start_did:$cursor} else . end')
      # -q 禁用远端 curlrc；授权通过标准输入配置传入，不进入进程参数。
      # 不跟随重定向，不刷新/写回授权。响应先在远端剔除 token 等无关字段。
      response=$({
        printf '%s\n' "$auth_header" \
          'header = "X-Client-BizId: haapi"' \
          'header = "Content-Type: application/json"' \
          'header = "X-Client-AppId: 2882303761520251711"'
        printf '%s' "$request" | jq -Rr '"data = " + (. | @json)'
      } | curl -q -fsS --connect-timeout 10 --max-time 30 -K - \
        "https://$api_host/app/v2/home/device_list_page") || fail '小米查询失败；401 请在 HA 重新登录，网络故障可用 --cached-only'
      page=$(printf '%s' "$response" | jq -ce --arg region "$region" --arg account "$account_key" '
        if .code != 0 or (.result.list | type) != "array" then
          error("小米设备接口返回错误或格式异常")
        else {kind:"cloud", account_key:$account, has_more:(.result.has_more // false),
          cursor:(.result.next_start_did // ""),
          devices:[.result.list[] | select(.did != null) |
            {identifier:(($region + "_" + (.did | tostring)) |
               ascii_downcase | gsub("[^a-z0-9]+"; "_") | gsub("^_|_$"; "")),
             name, ip:(.localip // .local_ip), mac, pid, urn:.spec_type}]}
        end') || fail '小米接口查询未成功，请检查 HA 中的小米授权状态'
      unset response
      printf '%s\n' "$page"
      more=$(printf '%s' "$page" | jq -r '.has_more')
      [ "$more" = true ] || break
      cursor=$(printf '%s' "$page" | jq -er '.cursor | select(type == "string" and length > 0)') || fail '小米分页缺少游标'
      seen_cursors=$(printf '%s' "$seen_cursors" | jq -ce --arg cursor "$cursor" '
        if index($cursor) != null then error("分页游标重复") else . + [$cursor] end') || fail '小米分页游标重复，已中止查询'
    done
    offset=$((offset + 150))
  done
  unset auth_header
done
if [ "$cache_count" -eq 0 ]; then
  printf '提示：未找到小米 Home 缓存，将仅使用设备注册表。\n' >&2
fi
REMOTE
then
  die 'SSH 读取失败；请检查登录权限、服务器指纹、远端依赖和 HA 配置目录'
fi
unset password

# 以 HA 注册表为设备范围，排除缓存中未注册/已移除的设备。
if ! jq -es '
  def text: if type == "string" then . else "" end;
  def mac:
    text | ascii_downcase | gsub("[:-]"; "") |
    if test("^[0-9a-f]{12}$") and . != "000000000000" and . != "ffffffffffff"
    then [scan("..")] | join(":") else "" end;
  def ip:
    text |
    if test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$") then
      split(".") | map(tonumber) |
      if all(.[]; . >= 0 and . <= 255) and . != [0,0,0,0]
      then map(tostring) | join(".") else "" end
    else "" end;
  def first_text: map(text) | map(select(length > 0)) | .[0] // "";
  def single_text:
    map(text) | map(select(length > 0)) | unique |
    if length == 1 then .[0] else "" end;
  def category:
    text | (try capture("^urn:miot-spec-v2:device:(?<kind>[^:]+):").kind catch "") as $kind |
    ({"air-monitor":"空气检测仪", "air-purifier":"空气净化器",
      "control-panel":"中控屏", "gateway":"网关", "lock":"门锁",
      "magnet-sensor":"门窗传感器", "occupancy-sensor":"人体存在传感器",
      "motion-sensor":"人体移动传感器", "outlet":"插座", "remote-control":"遥控器",
      "speaker":"音箱", "switch":"开关", "temperature-humidity-sensor":"温湿度计",
      "vacuum":"扫地机器人", "water-purifier":"净水器", "light":"灯具",
      "fan":"风扇", "air-conditioner":"空调", "curtain":"窗帘",
      "humidifier":"加湿器", "dehumidifier":"除湿机", "heater":"取暖器",
      "camera":"摄像头", "air-fresh":"新风机", "television":"电视",
      "refrigerator":"冰箱", "washer":"洗衣机", "router":"路由器"}[$kind] // $kind // "");
  if ([.[] | select(.kind == "registry")] | length) != 1
  then error("远端未返回唯一设备注册表") else . end |
  . as $input |
  [$input[] | select(.kind == "accounts") | .accounts[]] as $accounts |
  (reduce ($input[] | select(.kind == "cache") | .account_key as $key |
    .devices[] | . + {account_key:$key}) as $d
    ({}; .[$d.account_key][$d.identifier] += [$d])) as $cache |
  (reduce ($input[] | select(.kind == "cloud") | .account_key as $key |
    .devices[] | . + {account_key:$key}) as $d
    ({}; .[$d.account_key][$d.identifier] += [$d])) as $cloud |
  (reduce ($input[] | select(.kind == "neighbors") | .rows[]) as $n
    ({}; .[$n.ip] += [$n.mac | mac])) as $neighbors |
  [$input[] | select(.kind == "registry") | .devices[] |
    . as $device |
    [$accounts[] | select(any(.entry_ids[]; . as $id | $device.entry_ids | index($id)))] |
    # 无法确定账号时单独保留设备，不借用其他账号的缓存。
    (if length > 0 then . else [{key:"",uid:"",region:"",name:""}] end)[] as $account |
    [$device.identifiers[] | $cache[$account.key][.][]?] as $all_cached |
    ($all_cached | if length == 0 then [[]] else
      group_by([.home_id, (if .home_id == "" then .home_name else "" end)]) end)[] as $cached |
    [$device.identifiers[] | $cloud[$account.key][.][]?] as $live |
    (if ($live | length) > 0 then $live else $cached end) as $matches |
    # 部分蓝牙设备的 localip 实际是上报出口地址，不是设备自己的 IP。
    (any($matches[]; ((.pid | tostring) == "6" or (.pid | tostring) == "16"))) as $bluetooth |
    (if $bluetooth then [] else [$matches[].ip | ip] end |
      unique | map(select(length > 0))) as $ips |
    # 同一账号内的结果冲突时不任意选取；账号之间独立处理。
    (if ($ips | length) == 1 then $ips[0] else "" end) as $ip |
    ([$matches[].mac] | map(mac) | unique |
      map(select(length > 0))) as $macs |
    (if ($macs | length) > 0 then $macs else [$device.macs[]? | mac] |
      unique | map(select(length > 0)) end) as $macs |
    (($neighbors[$ip] // []) | unique | map(select(length > 0))) as $arp |
    ([$cached[].home_id] | single_text) as $home_id |
    ([$cached[].home_name] | single_text) as $home_name |
    {device_id:$device.id, account_key:$account.key, account:$account.name,
     account_id:$account.uid, region:$account.region,
     home_id:$home_id, home:$home_name,
     home_key:(if $home_id != "" then $home_id elif $home_name != "" then "name:" + $home_name else "" end),
     room:([$cached[].room_name] | single_text),
     device_type:([$live[].urn, $cached[].urn] | map(category) | first_text),
     name:([$device.name_by_user, $device.name, $matches[].name, $device.id] | first_text),
     ip:$ip, bluetooth:$bluetooth,
     mac:(if ($macs | length) == 1 then $macs[0]
          elif ($macs | length) == 0 and ($arp | length) == 1 then $arp[0]
          else "" end)}] |
  unique_by([.account_key, .home_key, .device_id]) |
  sort_by(.account_key, .home_key,
    (if .ip == "" then [1] else [0] + (.ip | split(".") | map(tonumber)) end), .name)
' "$work_dir/input.jsonl" >"$work_dir/devices.json"; then
  die '设备数据解析失败'
fi
if [[ "$format" == tsv ]]; then
  jq -r '(["账号", "账号ID", "地区", "家庭", "家庭ID", "名称", "房间", "设备类型", "MAC", "IP"] | @tsv),
    (.[] | [.account, .account_id, .region, .home, .home_id, .name, .room, .device_type, .mac, .ip] | @tsv)' "$work_dir/devices.json"
  jq -r '"共 \(length) 条设备记录；有 IP：\([.[] | select(.ip != "")] | length)，有 MAC：\([.[] | select(.mac != "")] | length)，蓝牙/BLE Mesh：\([.[] | select(.bluetooth)] | length)。"' "$work_dir/devices.json" >&2
else
  bold='' cyan='' dim='' reset=''
  if [[ -t 1 && "${NO_COLOR+x}" != x && "$no_color" -eq 0 ]]; then
    bold=$'\033[1m' cyan=$'\033[36m' dim=$'\033[2m' reset=$'\033[0m'
  fi
  columns=${COLUMNS:-132}
  if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
    columns=$(tput cols 2>/dev/null) || columns=132
  fi
  [[ "$columns" =~ ^[0-9]{2,4}$ ]] || columns=132
  columns=$((10#$columns))
  jq -r --arg bold "$bold" --arg cyan "$cyan" --arg dim "$dim" --arg reset "$reset" \
    --arg host "$host" --argjson columns "$columns" '
    # 常见 CJK/全角字符占两列；组合音标、变体选择符不另占列。
    def cell_width:
      if (. >= 768 and . <= 879) or (. >= 65024 and . <= 65039) or . == 8205 then 0
      elif (. >= 4352 and . <= 4607) or (. >= 11904 and . <= 42191) or
           (. >= 44032 and . <= 55203) or (. >= 63744 and . <= 64255) or
           (. >= 65040 and . <= 65049) or (. >= 65072 and . <= 65135) or
           (. >= 65281 and . <= 65376) or (. >= 65504 and . <= 65510) or
           (. >= 127744 and . <= 129791) or (. >= 131072 and . <= 262141) then 2
      else 1 end;
    def width: [explode[] | cell_width] | add // 0;
    def clean: gsub("[\u0000-\u001f\u007f-\u009f]"; " ");
    def fit($n):
      clean | if width <= $n then . else
        (reduce explode[] as $c ({s:[], w:0, done:false};
          ($c | cell_width) as $w |
          if .done or .w + $w > $n - 1 then .done=true
          else .s += [$c] | .w += $w end) | .s | implode) + "…"
      end | . + (" " * ($n - width));
    . as $devices |
    ([4, (length | tostring | length)] | max) as $index_width |
    ([25, $columns - $index_width - 51] | max) as $text_budget |
    ([5, ([20, ($text_budget * 0.23 | floor)] | min)] | max) as $room_width |
    ([8, ([22, ($text_budget * 0.27 | floor)] | min)] | max) as $type_width |
    ([12, ([48, $text_budget - $room_width - $type_width] | min)] | max) as $name_width |
    [$index_width, $name_width, $room_width, $type_width, 17, 15] as $widths |
    def line($left; $middle; $right):
      $dim + $left + ([$widths[] | "─" * (. + 2)] | join($middle)) + $right + $reset;
    def row:
      . as $cells | "│ " + ([range(0; 6) as $i | $cells[$i] | fit($widths[$i])] | join(" │ ")) + " │";
    def display_label($fallback): if . == "" then $fallback else clean end;
    "",
    ($bold + "小米 Home · 设备清单" + $reset + "  " + $dim + $host + $reset),
    ("共 \([.[].account_key | select(. != "")] | unique | length) 个账号  ·  \(length) 条设备记录  ·  有 IP \([.[] | select(.ip != "")] | length) 条  ·  有 MAC \([.[] | select(.mac != "")] | length) 条"),
    "",
    (group_by(.account_key)[] |
      ($bold + "账号：" + (.[0].account | display_label("未识别账号")) + $reset +
       "  [ID: " + (.[0].account_id | display_label("未知")) + " · 地区: " + (.[0].region | display_label("未知")) + "]"),
      (group_by(.home_key)[] |
        ("  家庭：" + (.[0].home | display_label("未分配家庭")) +
         "  [ID: " + (.[0].home_id | display_label("未知")) + "]  ·  \(length) 台"),
        line("┌"; "┬"; "┐"),
        ($cyan + $bold + (["序号", "设备名称", "房间", "设备类型", "MAC 地址", "IP 地址"] | row) + $reset),
        line("├"; "┼"; "┤"),
        (to_entries[] | [(.key + 1 | tostring), .value.name, .value.room, .value.device_type, .value.mac, .value.ip] | row),
        line("└"; "┴"; "┘"), "")),
    ($dim + "各家庭内按 IPv4 升序；空白表示无独立 IP 或数据缺失。完整字段可通过 --format tsv 导出。" + $reset),
    ""
  ' "$work_dir/devices.json"
fi
