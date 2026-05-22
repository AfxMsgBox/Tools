#!/usr/bin/env bash
set -u

usage() {
  cat <<'USAGE'
用法:
  ./url_speed_test.sh <URL> <次数>

示例:
  ./url_speed_test.sh "https://example.com" 5
USAGE
}

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

URL="$1"
COUNT="$2"

if ! [[ "$COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "错误: 次数必须是正整数。" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "错误: 未找到 curl，请先安装 curl。" >&2
  exit 1
fi

# 累加变量（秒）
sum_namelookup=0
sum_connect=0
sum_appconnect=0
sum_pretransfer=0
sum_starttransfer=0
sum_total=0
sum_speed=0
sum_size=0
sum_upload_size=0
sum_upload_speed=0

success_count=0
curl_fail_count=0
http_error_count=0

printf "开始测试: %s\n总次数: %s\n\n" "$URL" "$COUNT"

index_width=${#COUNT}

for ((i = 1; i <= COUNT; i++)); do
  out="$(curl -o /dev/null -sS -L \
    --connect-timeout 10 \
    --max-time 30 \
    -w "code=%{http_code} namelookup=%{time_namelookup} connect=%{time_connect} appconnect=%{time_appconnect} pretransfer=%{time_pretransfer} starttransfer=%{time_starttransfer} total=%{time_total} speed=%{speed_download} size=%{size_download} upload_size=%{size_upload} upload_speed=%{speed_upload} final_url=%{url_effective} redirects=%{num_redirects}" \
    "$URL" 2>&1)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    ((curl_fail_count++))
    idx=$(printf "%${index_width}d" "$i")
    printf "[%s/%d] CURL失败: %s\n" "$idx" "$COUNT" "$out"
    continue
  fi

  code="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^code=/){sub("code=","",$i); print $i}}' <<<"$out")"
  namelookup="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^namelookup=/){sub("namelookup=","",$i); print $i}}' <<<"$out")"
  connect="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^connect=/){sub("connect=","",$i); print $i}}' <<<"$out")"
  appconnect="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^appconnect=/){sub("appconnect=","",$i); print $i}}' <<<"$out")"
  pretransfer="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^pretransfer=/){sub("pretransfer=","",$i); print $i}}' <<<"$out")"
  starttransfer="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^starttransfer=/){sub("starttransfer=","",$i); print $i}}' <<<"$out")"
  total="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^total=/){sub("total=","",$i); print $i}}' <<<"$out")"
  speed="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^speed=/){sub("speed=","",$i); print $i}}' <<<"$out")"
  size="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^size=/){sub("size=","",$i); print $i}}' <<<"$out")"
  upload_size="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^upload_size=/){sub("upload_size=","",$i); print $i}}' <<<"$out")"
  upload_speed="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^upload_speed=/){sub("upload_speed=","",$i); print $i}}' <<<"$out")"
  final_url="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^final_url=/){sub("final_url=","",$i); print $i}}' <<<"$out")"
  redirects="$(awk '{for(i=1;i<=NF;i++) if($i ~ /^redirects=/){sub("redirects=","",$i); print $i}}' <<<"$out")"

  if [[ "$code" -lt 200 || "$code" -ge 400 ]]; then
    ((http_error_count++))
    idx=$(printf "%${index_width}d" "$i")
    printf "[%s/%d] HTTP异常 code=%s total=%ss dl_speed=%sB/s dl_size=%sB ul_speed=%sB/s ul_size=%sB redirects=%s final_url=%s\n" "$idx" "$COUNT" "$code" "$total" "$speed" "$size" "$upload_speed" "$upload_size" "$redirects" "$final_url"
    continue
  fi

  ((success_count++))

  sum_namelookup=$(awk -v a="$sum_namelookup" -v b="$namelookup" 'BEGIN{printf "%.6f", a+b}')
  sum_connect=$(awk -v a="$sum_connect" -v b="$connect" 'BEGIN{printf "%.6f", a+b}')
  sum_appconnect=$(awk -v a="$sum_appconnect" -v b="$appconnect" 'BEGIN{printf "%.6f", a+b}')
  sum_pretransfer=$(awk -v a="$sum_pretransfer" -v b="$pretransfer" 'BEGIN{printf "%.6f", a+b}')
  sum_starttransfer=$(awk -v a="$sum_starttransfer" -v b="$starttransfer" 'BEGIN{printf "%.6f", a+b}')
  sum_total=$(awk -v a="$sum_total" -v b="$total" 'BEGIN{printf "%.6f", a+b}')
  sum_speed=$(awk -v a="$sum_speed" -v b="$speed" 'BEGIN{printf "%.2f", a+b}')
  sum_size=$(awk -v a="$sum_size" -v b="$size" 'BEGIN{printf "%.0f", a+b}')
  sum_upload_size=$(awk -v a="$sum_upload_size" -v b="$upload_size" 'BEGIN{printf "%.0f", a+b}')
  sum_upload_speed=$(awk -v a="$sum_upload_speed" -v b="$upload_speed" 'BEGIN{printf "%.2f", a+b}')

  idx=$(printf "%${index_width}d" "$i")
  printf "[%s/%d] OK code=%s total=%ss connect=%ss tls=%ss ttfb=%ss dl_speed=%sB/s dl_size=%sB ul_speed=%sB/s ul_size=%sB redirects=%s final_url=%s\n" \
    "$idx" "$COUNT" "$code" "$total" "$connect" "$appconnect" "$starttransfer" "$speed" "$size" "$upload_speed" "$upload_size" "$redirects" "$final_url"
done

echo
printf "测试完成。\n"
printf "总请求: %d\n" "$COUNT"
printf "成功(2xx/3xx): %d\n" "$success_count"
printf "HTTP异常(4xx/5xx/其他): %d\n" "$http_error_count"
printf "CURL失败(超时/网络/DNS/TLS等): %d\n" "$curl_fail_count"

if [[ "$success_count" -eq 0 ]]; then
  echo "\n没有可用于计算平均值的成功请求。"
  exit 2
fi

avg_namelookup=$(awk -v s="$sum_namelookup" -v n="$success_count" 'BEGIN{printf "%.6f", s/n}')
avg_connect=$(awk -v s="$sum_connect" -v n="$success_count" 'BEGIN{printf "%.6f", s/n}')
avg_appconnect=$(awk -v s="$sum_appconnect" -v n="$success_count" 'BEGIN{printf "%.6f", s/n}')
avg_pretransfer=$(awk -v s="$sum_pretransfer" -v n="$success_count" 'BEGIN{printf "%.6f", s/n}')
avg_starttransfer=$(awk -v s="$sum_starttransfer" -v n="$success_count" 'BEGIN{printf "%.6f", s/n}')
avg_total=$(awk -v s="$sum_total" -v n="$success_count" 'BEGIN{printf "%.6f", s/n}')
avg_speed=$(awk -v s="$sum_speed" -v n="$success_count" 'BEGIN{printf "%.2f", s/n}')
avg_size=$(awk -v s="$sum_size" -v n="$success_count" 'BEGIN{printf "%.0f", s/n}')
avg_upload_size=$(awk -v s="$sum_upload_size" -v n="$success_count" 'BEGIN{printf "%.0f", s/n}')
avg_upload_speed=$(awk -v s="$sum_upload_speed" -v n="$success_count" 'BEGIN{printf "%.2f", s/n}')

echo "\n====== 平均值（仅统计成功请求） ======"
printf "DNS解析时间(time_namelookup):   %ss\n" "$avg_namelookup"
printf "TCP连接时间(time_connect):       %ss\n" "$avg_connect"
printf "TLS握手时间(time_appconnect):    %ss (HTTP时通常为0)\n" "$avg_appconnect"
printf "请求准备时间(time_pretransfer):  %ss\n" "$avg_pretransfer"
printf "首字节时间(time_starttransfer):  %ss\n" "$avg_starttransfer"
printf "总耗时(time_total):              %ss\n" "$avg_total"
printf "平均下载速度(speed_download):    %s B/s\n" "$avg_speed"
printf "平均下载大小(size_download):     %s bytes\n" "$avg_size"
printf "平均上传速度(speed_upload):      %s B/s\n" "$avg_upload_speed"
printf "平均上传大小(size_upload):       %s bytes\n" "$avg_upload_size"
