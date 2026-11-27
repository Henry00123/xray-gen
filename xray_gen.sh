#!/usr/bin/env bash
# Xray-core 配置生成与修改脚本 (Bash + jq)
# 功能：
# 1. 自动读取当前目录 ./config.json（或 -c/-o 指定文件），解析并展示当前入站/出站及 TLS 证书路径
# 2. 支持只修改入站、只修改出站、只设置/修改入站 TLS 证书路径，保留原有 routing/dns/log 等配置
# 3. 支持入站：SOCKS5、HTTP、SOCKS5+HTTP、VLESS、Shadowsocks、Dokodemo-door
# 4. 支持出站：直连 (freedom)、手动配置协议、从分享链接解析 (vless/vmess/trojan/ss/socks5/http)
# 5. 支持脚本自更新 (-u/--update 或交互式菜单)，支持自定义更新地址与镜像源
# 6. 支持通过官方 install-release.sh 安装/更新/卸载 Xray，以及 Xray 状态监测与服务启停管理

set -euo pipefail

# ==================== 环境与依赖检查 ====================

check_deps() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "错误：未找到 jq，请先安装后再运行。" >&2
    echo "  Debian/Ubuntu: sudo apt update && sudo apt install -y jq" >&2
    echo "  CentOS/RHEL:   sudo yum install -y jq" >&2
    echo "  Alpine:        apk add jq" >&2
    echo "  macOS:         brew install jq" >&2
    exit 1
  fi
  if ! command -v base64 >/dev/null 2>&1; then
    echo "错误：未找到 base64 命令。" >&2
    exit 1
  fi
}

# 兼容 GNU base64 (-d) 与 macOS BSD base64 (-D)
B64_DEC_FLAG="-d"
if ! printf 'YQ==' | base64 -d >/dev/null 2>&1; then
  B64_DEC_FLAG="-D"
fi

# ==================== 终端样式与通用辅助函数 ====================

C_RESET=""
C_BOLD=""
C_DIM=""
C_CYAN=""
C_GREEN=""
C_YELLOW=""
C_RED=""

if [[ -t 2 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
fi

ui_hr() {
  printf '%s──────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET" >&2
}

ui_header() {
  local title="$1"
  local subtitle="${2:-}"
  echo "" >&2
  ui_hr
  if [[ -n "$subtitle" ]]; then
    printf '  %s%s◆ %s%s  %s%s%s\n' "$C_BOLD" "$C_CYAN" "$title" "$C_RESET" "$C_DIM" "$subtitle" "$C_RESET" >&2
  else
    printf '  %s%s◆ %s%s\n' "$C_BOLD" "$C_CYAN" "$title" "$C_RESET" >&2
  fi
  ui_hr
}

ui_section() {
  local title="$1"
  local note="${2:-}"
  if [[ -n "$note" ]]; then
    printf '%s%s▸ %s%s %s%s%s\n' "$C_BOLD" "$C_CYAN" "$title" "$C_RESET" "$C_DIM" "$note" "$C_RESET" >&2
  else
    printf '%s%s▸ %s%s\n' "$C_BOLD" "$C_CYAN" "$title" "$C_RESET" >&2
  fi
}

ui_item() {
  local key="$1"
  local label="$2"
  local desc="${3:-}"
  local color="${4:-$C_CYAN}"
  if [[ -n "$desc" ]]; then
    printf '  %s%s[%s]%s %s%s%s %s— %s%s\n' \
      "$C_BOLD" "$color" "$key" "$C_RESET" \
      "$C_BOLD" "$label" "$C_RESET" \
      "$C_DIM" "$desc" "$C_RESET" >&2
  else
    printf '  %s%s[%s]%s %s%s%s\n' \
      "$C_BOLD" "$color" "$key" "$C_RESET" \
      "$C_BOLD" "$label" "$C_RESET" >&2
  fi
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local val=""
  if [[ -n "$default" ]]; then
    read -r -p "${C_CYAN}❯${C_RESET} ${prompt} ${C_DIM}[${default}]${C_RESET}: " val
  else
    read -r -p "${C_CYAN}❯${C_RESET} ${prompt}: " val
  fi
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  if [[ -z "$val" ]]; then
    printf '%s' "$default"
  else
    printf '%s' "$val"
  fi
}

ask_required() {
  local prompt="$1"
  local default="${2:-}"
  local val
  while true; do
    val="$(ask "$prompt" "$default")"
    if [[ -n "$val" ]]; then
      printf '%s' "$val"
      return 0
    fi
    echo "该项不能为空，请重新输入。" >&2
  done
}

is_valid_port() {
  local p="${1:-}"
  [[ "$p" =~ ^[1-9][0-9]*$ ]] && (( p >= 1 && p <= 65535 ))
}

ask_port() {
  local prompt="$1"
  local default="$2"
  local val
  while true; do
    val="$(ask "$prompt" "$default")"
    if is_valid_port "$val"; then
      printf '%s' "$val"
      return 0
    fi
    echo "请输入 1-65535 之间的有效端口号（不含前导零）。" >&2
  done
}

ask_yes_no() {
  local prompt="$1"
  local default="${2:-n}"
  local hint="y/N"
  [[ "$default" == "y" ]] && hint="Y/n"
  local val=""
  read -r -p "${C_CYAN}❯${C_RESET} ${prompt} ${C_DIM}(${hint})${C_RESET}: " val
  val="$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$val" ]]; then
    [[ "$default" == "y" ]]
    return
  fi
  [[ "$val" == "y" || "$val" == "yes" || "$val" == "1" || "$val" == "true" ]]
}

gen_uuid() {
  if command -v xray >/dev/null 2>&1; then
    xray uuid 2>/dev/null && return 0
  fi
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
    return 0
  fi
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  printf '%04x%04x-%04x-%04x-%04x-%04x%04x%04x\n' \
    $RANDOM $RANDOM $RANDOM $(( ($RANDOM & 0x0fff) | 0x4000 )) \
    $(( ($RANDOM & 0x3fff) | 0x8000 )) $RANDOM $RANDOM $RANDOM
}

url_decode() {
  local s="$1"
  local out=""
  local i=0 len=${#s} c hex
  while (( i < len )); do
    c="${s:i:1}"
    if [[ "$c" == "%" && $((i + 2)) -lt len ]]; then
      hex="${s:i+1:2}"
      if [[ "$hex" =~ ^[0-9a-fA-F]{2}$ ]]; then
        out+="\\x${hex}"
        i=$((i + 3))
        continue
      fi
    elif [[ "$c" == "\\" ]]; then
      out+="\\\\"
      i=$((i + 1))
      continue
    fi
    out+="$c"
    i=$((i + 1))
  done
  printf -- '%b' "$out"
}

b64_decode() {
  local s
  s="$(printf '%s' "$1" | tr -d '\r\n ' | tr '_-' '/+')"
  local mod=$(( ${#s} % 4 ))
  if (( mod == 2 )); then
    s+="=="
  elif (( mod == 3 )); then
    s+="="
  fi
  printf '%s' "$s" | base64 "$B64_DEC_FLAG" 2>/dev/null
}

# 解析 host:port（兼容 IPv6 [::1]:443），结果写入 HP_HOST 和 HP_PORT
split_host_port() {
  local hp="$1"
  local default_port="$2"
  HP_HOST=""
  HP_PORT="$default_port"
  if [[ "$hp" =~ ^\[([^\]]+)\]:([^:]*)$ ]]; then
    HP_HOST="${BASH_REMATCH[1]}"
    HP_PORT="${BASH_REMATCH[2]}"
  elif [[ "$hp" =~ ^\[([^\]]+)\]$ ]]; then
    HP_HOST="${BASH_REMATCH[1]}"
    HP_PORT="$default_port"
  elif [[ "$hp" == *:*:* ]]; then
    echo "IPv6 地址请使用方括号格式 [ipv6]:port" >&2
    return 1
  elif [[ "$hp" == *:* ]]; then
    HP_HOST="${hp%:*}"
    HP_PORT="${hp##*:}"
  else
    HP_HOST="$hp"
    HP_PORT="$default_port"
  fi

  if [[ "$HP_PORT" == "$default_port" && "$default_port" == "0" ]]; then
    return 0
  fi
  if ! is_valid_port "$HP_PORT"; then
    echo "端口号无效: ${HP_PORT:-<空>}（有效范围 1-65535）" >&2
    return 1
  fi
}

get_qparam() {
  local query="$1"
  local key="$2"
  [[ -z "$query" ]] && return 0
  local -a pairs=()
  local IFS='&'
  read -r -a pairs <<< "$query"
  local pair k v
  for pair in "${pairs[@]}"; do
    k="${pair%%=*}"
    if [[ "$k" == "$key" ]]; then
      if [[ "$pair" == *=* ]]; then
        v="${pair#*=}"
        url_decode "$v"
      fi
      return 0
    fi
  done
}

# ==================== 读取与展示现有 config.json ====================

BASE_CONFIG_JSON=""
INBOUNDS_JSON="[]"
OUTBOUNDS_JSON="[]"

# 返回值: 0=加载成功, 1=文件不存在, 2=文件存在但无法解析为合法 JSON 对象
load_existing_config() {
  local file="$1"
  BASE_CONFIG_JSON=""
  INBOUNDS_JSON="[]"
  OUTBOUNDS_JSON="[]"

  if [[ ! -f "$file" ]]; then
    return 1
  fi
  if ! jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
    return 2
  fi

  BASE_CONFIG_JSON="$(cat "$file")"
  INBOUNDS_JSON="$(printf '%s' "$BASE_CONFIG_JSON" | jq '.inbounds // []')"
  OUTBOUNDS_JSON="$(printf '%s' "$BASE_CONFIG_JSON" | jq '.outbounds // []')"
  return 0
}

show_inbounds_summary() {
  local json_arr="$1"
  local count
  count="$(printf '%s' "$json_arr" | jq 'length')"
  ui_section "入站列表" "(inbounds: ${count} 条)"
  if (( count == 0 )); then
    printf '  %s(无入站配置)%s\n' "$C_DIM" "$C_RESET" >&2
    return
  fi
  printf '%s' "$json_arr" | jq -r \
    --arg r "$C_RESET" \
    --arg b "$C_BOLD" \
    --arg d "$C_DIM" \
    --arg c "$C_CYAN" \
    --arg y "$C_YELLOW" \
    --arg g "$C_GREEN" '
    to_entries[] |
    (.key + 1) as $idx |
    .value as $v |
    (
      if $v.streamSettings then
        " \($c)[\($v.streamSettings.network // "raw")/\($v.streamSettings.security // "none")]\($r)"
      else "" end
    ) as $stream |
    (
      if ($v.protocol == "vless" and ($v.settings.decryption // "none") != "none") then
        " \($g)(VLESS-Enc)\($r)"
      elif ($v.protocol == "socks" and ($v.settings.auth // "noauth") == "password") then
        " \($g)(auth:password)\($r)"
      else "" end
    ) as $extra |
    (
      if (($v.streamSettings.tlsSettings.certificates // []) | type == "array" and length > 0) then
        "\n      \($d)├─ TLS cert:\($r) \($v.streamSettings.tlsSettings.certificates[0].certificateFile // "-")\n      \($d)└─ TLS key: \($r) \($v.streamSettings.tlsSettings.certificates[0].keyFile // "-")"
      else "" end
    ) as $tls_info |
    "  \($b)\($c)[\($idx)]\($r) \($d)tag=\($r)\($b)\($v.tag // "-")\($r) \($d)|\($r) \($y)\($v.protocol // "-")\($r) \($d)|\($r) \($v.listen // "0.0.0.0"):\($v.port // "-")\($stream)\($extra)\($tls_info)"
  ' >&2
}

show_outbounds_summary() {
  local json_arr="$1"
  local count
  count="$(printf '%s' "$json_arr" | jq 'length')"
  ui_section "出站列表" "(outbounds: ${count} 条，第 1 条为默认主出站)"
  if (( count == 0 )); then
    printf '  %s(无出站配置)%s\n' "$C_DIM" "$C_RESET" >&2
    return
  fi
  printf '%s' "$json_arr" | jq -r \
    --arg r "$C_RESET" \
    --arg b "$C_BOLD" \
    --arg d "$C_DIM" \
    --arg c "$C_CYAN" \
    --arg y "$C_YELLOW" \
    --arg g "$C_GREEN" '
    to_entries[] |
    (.key + 1) as $idx |
    .value as $v |
    (
      if $v.settings.address then
        "\($v.settings.address):\($v.settings.port // "")"
      elif ($v.settings.vnext | type == "array" and length > 0) then
        "\($v.settings.vnext[0].address):\($v.settings.vnext[0].port)"
      elif ($v.settings.servers | type == "array" and length > 0) then
        "\($v.settings.servers[0].address):\($v.settings.servers[0].port)"
      elif $v.protocol == "freedom" then
        "直连 (\($v.settings.domainStrategy // "AsIs"))"
      elif $v.protocol == "blackhole" then
        "拦截"
      else "-" end
    ) as $target |
    (
      if $v.streamSettings then
        " \($c)[\($v.streamSettings.network // "raw")/\($v.streamSettings.security // "none")]\($r)"
      else "" end
    ) as $stream |
    (
      if ($v.protocol == "vless" and ($v.settings.encryption // "none") != "none") then
        " \($g)(VLESS-Enc)\($r)"
      else "" end
    ) as $extra |
    (if $idx == 1 then "\($b)\($g)★\($r) " else "  " end) as $mark |
    (if $idx == 1 then " \($g)(默认主出站)\($r)" else "" end) as $primary_badge |
    "  \($b)\($c)[\($idx)]\($r) \($mark)\($d)tag=\($r)\($b)\($v.tag // "-")\($r) \($d)|\($r) \($y)\($v.protocol // "-")\($r) \($d)|\($r) \($target)\($stream)\($extra)\($primary_badge)"
  ' >&2
}

show_config_summary() {
  local file="$1"
  echo "" >&2
  ui_hr
  printf '  %s%s◆ Xray 配置摘要%s  %s%s%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_DIM" "$file" "$C_RESET" >&2
  printf '  %s● Xray 状态:%s %s\n' "$C_DIM" "$C_RESET" "$(get_xray_brief_status)" >&2
  ui_hr
  show_inbounds_summary "$INBOUNDS_JSON"
  echo "" >&2
  show_outbounds_summary "$OUTBOUNDS_JSON"
  ui_hr
}

# ==================== 设置/修改入站 TLS 证书路径 ====================

apply_tls_to_inbound() {
  local idx="$1"
  local cert="$2"
  local key="$3"

  local count
  count="$(printf '%s' "$INBOUNDS_JSON" | jq 'length')"
  if (( count == 0 )); then
    echo "错误：当前配置中没有入站，无法设置 TLS 路径。" >&2
    return 1
  fi
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > count )); then
    echo "错误：入站序号 ${idx} 无效（当前共 ${count} 条入站）。" >&2
    return 1
  fi

  local zero_idx=$((idx - 1))
  local cur_cert cur_key
  cur_cert="$(printf '%s' "$INBOUNDS_JSON" | jq -r --argjson i "$zero_idx" '.[$i].streamSettings.tlsSettings.certificates[0].certificateFile // ""')"
  cur_key="$(printf '%s' "$INBOUNDS_JSON" | jq -r --argjson i "$zero_idx" '.[$i].streamSettings.tlsSettings.certificates[0].keyFile // ""')"

  [[ -z "$cert" ]] && cert="$cur_cert"
  [[ -z "$key" ]] && key="$cur_key"

  if [[ -z "$cert" || -z "$key" ]]; then
    echo "错误：TLS 证书路径 (certificateFile) 和私钥路径 (keyFile) 均不能为空。" >&2
    return 1
  fi

  if [[ ! -f "$cert" ]]; then
    echo "提示：本地未检测到证书文件（仍会写入配置）: ${cert}" >&2
  fi
  if [[ ! -f "$key" ]]; then
    echo "提示：本地未检测到私钥文件（仍会写入配置）: ${key}" >&2
  fi

  INBOUNDS_JSON="$(printf '%s' "$INBOUNDS_JSON" | jq \
    --argjson i "$zero_idx" \
    --arg cert "$cert" \
    --arg key "$key" '
    .[$i].streamSettings = (
      (.[$i].streamSettings // {})
      | .network = (.network // "raw")
      | .security = "tls"
      | del(.realitySettings)
      | .tlsSettings = (
          (.tlsSettings // {})
          | .certificates = [
              (((.certificates // [])[0] // {}) + { certificateFile: $cert, keyFile: $key })
            ] + ((.certificates // [])[1:])
        )
    )
  ')"
  echo "已更新第 ${idx} 条入站的 TLS 证书路径。" >&2
}

configure_tls_cert_paths_interactive() {
  local count
  count="$(printf '%s' "$INBOUNDS_JSON" | jq 'length')"
  if (( count == 0 )); then
    echo "当前没有入站配置，请先添加入站。" >&2
    return 1
  fi

  echo "" >&2
  show_inbounds_summary "$INBOUNDS_JSON"

  local idx="1"
  if (( count > 1 )); then
    idx="$(ask "请选择要设置 TLS 路径的入站序号 (1-${count})" "1")"
  fi
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > count )); then
    echo "错误：无效的入站序号。" >&2
    return 1
  fi

  local zero_idx=$((idx - 1))
  local cur_cert cur_key
  cur_cert="$(printf '%s' "$INBOUNDS_JSON" | jq -r --argjson i "$zero_idx" '.[$i].streamSettings.tlsSettings.certificates[0].certificateFile // ""')"
  cur_key="$(printf '%s' "$INBOUNDS_JSON" | jq -r --argjson i "$zero_idx" '.[$i].streamSettings.tlsSettings.certificates[0].keyFile // ""')"

  local default_cert="${cur_cert:-/etc/xray/fullchain.pem}"
  local default_key="${cur_key:-/etc/xray/privkey.pem}"

  local cert key
  cert="$(ask "TLS 证书文件路径 (certificateFile)" "$default_cert")"
  key="$(ask "TLS 私钥文件路径 (keyFile)" "$default_key")"

  apply_tls_to_inbound "$idx" "$cert" "$key"
}

# ==================== 统一构建 streamSettings ====================

build_stream_settings() {
  local network="${1:-raw}"
  local security="${2:-none}"
  local host_fallback="${3:-}"
  local path="${4:-}"
  local host="${5:-}"
  local header_type="${6:-}"
  local mode="${7:-}"
  local service_name="${8:-}"
  local authority="${9:-}"
  local seed="${10:-}"
  local extra="${11:-}"
  local sni="${12:-}"
  local fp="${13:-}"
  local alpn="${14:-}"
  local pcs="${15:-}"
  local vcn="${16:-}"
  local pbk="${17:-}"
  local sid="${18:-}"
  local spx="${19:-}"
  local pqv="${20:-}"

  network="$(printf '%s' "$network" | tr '[:upper:]' '[:lower:]')"
  [[ -z "$network" ]] && network="raw"
  [[ "$network" == "splithttp" ]] && network="xhttp"

  security="$(printf '%s' "$security" | tr '[:upper:]' '[:lower:]')"
  [[ -z "$security" ]] && security="none"

  jq -n \
    --arg net "$network" \
    --arg sec "$security" \
    --arg host_fb "$host_fallback" \
    --arg path "$path" \
    --arg host "$host" \
    --arg htype "$header_type" \
    --arg mode "$mode" \
    --arg sname "$service_name" \
    --arg auth "$authority" \
    --arg seed "$seed" \
    --arg extra "$extra" \
    --arg sni "$sni" \
    --arg fp "$fp" \
    --arg alpn "$alpn" \
    --arg pcs "$pcs" \
    --arg vcn "$vcn" \
    --arg pbk "$pbk" \
    --arg sid "$sid" \
    --arg spx "$spx" \
    --arg pqv "$pqv" '
    def csv_list: split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0));

    { network: $net, security: $sec }

    | if ($net == "raw" or $net == "tcp") and $htype == "http" then
        . + {
          (if $net == "raw" then "rawSettings" else "tcpSettings" end): {
            header: {
              type: "http",
              request: {
                path: [if $path != "" then $path else "/" end],
                headers: (if $host != "" then { Host: ($host | csv_list) } else {} end)
              }
            }
          }
        }
      elif $net == "ws" then
        . + {
          wsSettings: (
            { path: (if $path != "" then $path else "/" end) }
            + (if $host != "" then { host: $host } else {} end)
          )
        }
      elif $net == "httpupgrade" then
        . + {
          httpupgradeSettings: (
            { path: (if $path != "" then $path else "/" end) }
            + (if $host != "" then { host: $host } else {} end)
          )
        }
      elif $net == "xhttp" then
        . + {
          xhttpSettings: (
            { path: (if $path != "" then $path else "/" end) }
            + (if $host != "" then { host: $host } else {} end)
            + (if $mode != "" then { mode: $mode } else {} end)
            + (if $extra != "" then (try { extra: ($extra | fromjson) } catch {}) else {} end)
          )
        }
      elif $net == "grpc" then
        . + {
          grpcSettings: (
            { serviceName: (if $sname != "" then $sname else ($path | ltrimstr("/")) end) }
            + (if $mode == "multi" then { multiMode: true } else {} end)
            + (if $auth != "" then { authority: $auth } else {} end)
          )
        }
      elif $net == "kcp" then
        (
          (if $htype != "" and $htype != "none" then { header: { type: $htype } } else {} end)
          + (if $seed != "" then { seed: $seed } else {} end)
        ) as $kcp
        | if ($kcp | length) > 0 then . + { kcpSettings: $kcp } else . end
      else .
      end

    | if $sec == "tls" then
        (if $sni != "" then $sni elif $host != "" then $host else $host_fb end) as $final_sni
        | . + {
          tlsSettings: (
            (if $final_sni != "" then { serverName: $final_sni } else {} end)
            + (if $fp != "" then { fingerprint: $fp } else {} end)
            + (if $alpn != "" then { alpn: ($alpn | csv_list) } else {} end)
            + (if $pcs != "" then { pinnedPeerCertSha256: $pcs } else {} end)
            + (if $vcn != "" then { verifyPeerCertByName: $vcn } else {} end)
          )
        }
      elif $sec == "reality" then
        . + {
          realitySettings: (
            {
              serverName: (if $sni != "" then $sni else $host_fb end),
              fingerprint: (if $fp != "" then $fp else "chrome" end),
              publicKey: $pbk,
              shortId: $sid
            }
            + (if $spx != "" then { spiderX: $spx } else {} end)
            + (if $pqv != "" then { mldsa65Verify: $pqv } else {} end)
          )
        }
      else .
      end
  '
}

# ==================== 协议分享链接解析 ====================

parse_vless_link() {
  local link="$1" tag="${2:-proxy}"
  local rest="${link#*://}"
  rest="${rest%%#*}"
  local query=""
  if [[ "$rest" == *\?* ]]; then
    query="${rest#*\?}"
    rest="${rest%%\?*}"
  fi
  local authority="${rest%%/*}"
  if [[ "$authority" != *@* ]]; then
    echo "VLESS 链接缺少 UUID" >&2
    return 1
  fi
  local user_id hostport
  user_id="$(url_decode "${authority%@*}")"
  hostport="${authority##*@}"
  if ! split_host_port "$hostport" 443; then
    return 1
  fi
  if [[ -z "$HP_HOST" || -z "$user_id" ]]; then
    echo "VLESS 链接缺少服务器地址或 UUID" >&2
    return 1
  fi

  local encryption flow network security path host htype mode sname auth seed extra sni fp alpn pcs vcn pbk sid spx pqv
  encryption="$(get_qparam "$query" "encryption")"; [[ -z "$encryption" ]] && encryption="none"
  flow="$(get_qparam "$query" "flow")"
  network="$(get_qparam "$query" "type")"; [[ -z "$network" ]] && network="raw"
  security="$(get_qparam "$query" "security")"; [[ -z "$security" ]] && security="none"
  path="$(get_qparam "$query" "path")"
  host="$(get_qparam "$query" "host")"
  htype="$(get_qparam "$query" "headerType")"
  mode="$(get_qparam "$query" "mode")"
  sname="$(get_qparam "$query" "serviceName")"
  auth="$(get_qparam "$query" "authority")"
  seed="$(get_qparam "$query" "seed")"
  extra="$(get_qparam "$query" "extra")"
  sni="$(get_qparam "$query" "sni")"; [[ -z "$sni" ]] && sni="$(get_qparam "$query" "peer")"
  fp="$(get_qparam "$query" "fp")"
  alpn="$(get_qparam "$query" "alpn")"
  pcs="$(get_qparam "$query" "pcs")"; [[ -z "$pcs" ]] && pcs="$(get_qparam "$query" "pinnedPeerCertSha256")"
  vcn="$(get_qparam "$query" "vcn")"; [[ -z "$vcn" ]] && vcn="$(get_qparam "$query" "verifyPeerCertByName")"
  pbk="$(get_qparam "$query" "pbk")"
  sid="$(get_qparam "$query" "sid")"
  spx="$(get_qparam "$query" "spx")"
  pqv="$(get_qparam "$query" "pqv")"

  local stream_json
  stream_json="$(build_stream_settings "$network" "$security" "$HP_HOST" "$path" "$host" "$htype" "$mode" "$sname" "$auth" "$seed" "$extra" "$sni" "$fp" "$alpn" "$pcs" "$vcn" "$pbk" "$sid" "$spx" "$pqv")"

  jq -n \
    --arg tag "$tag" \
    --arg addr "$HP_HOST" \
    --argjson port "$HP_PORT" \
    --arg id "$user_id" \
    --arg enc "$encryption" \
    --arg flow "$flow" \
    --argjson stream "$stream_json" '
    {
      tag: $tag,
      protocol: "vless",
      settings: (
        { address: $addr, port: $port, id: $id, encryption: $enc }
        + (if $flow != "" then { flow: $flow } else {} end)
      ),
      streamSettings: $stream
    }
  '
}

parse_vmess_link() {
  local link="$1" tag="${2:-proxy}"
  local raw_body="${link#*://}"
  local before_hash="${raw_body%%#*}"

  if [[ "$before_hash" == *@* ]]; then
    local query=""
    local rest="$before_hash"
    if [[ "$rest" == *\?* ]]; then
      query="${rest#*\?}"
      rest="${rest%%\?*}"
    fi
    local authority="${rest%%/*}"
    local user_id hostport
    user_id="$(url_decode "${authority%@*}")"
    hostport="${authority##*@}"
    if ! split_host_port "$hostport" 443; then
      return 1
    fi
    if [[ -z "$HP_HOST" || -z "$user_id" ]]; then
      echo "VMess AEAD 链接缺少地址或 UUID" >&2
      return 1
    fi
    local scy network security path host htype mode sname auth seed extra sni fp alpn
    scy="$(get_qparam "$query" "encryption")"; [[ -z "$scy" ]] && scy="auto"
    network="$(get_qparam "$query" "type")"; [[ -z "$network" ]] && network="tcp"
    security="$(get_qparam "$query" "security")"; [[ -z "$security" ]] && security="none"
    path="$(get_qparam "$query" "path")"
    host="$(get_qparam "$query" "host")"
    htype="$(get_qparam "$query" "headerType")"
    mode="$(get_qparam "$query" "mode")"
    sname="$(get_qparam "$query" "serviceName")"
    auth="$(get_qparam "$query" "authority")"
    seed="$(get_qparam "$query" "seed")"
    extra="$(get_qparam "$query" "extra")"
    sni="$(get_qparam "$query" "sni")"
    fp="$(get_qparam "$query" "fp")"
    alpn="$(get_qparam "$query" "alpn")"

    local stream_json
    stream_json="$(build_stream_settings "$network" "$security" "$HP_HOST" "$path" "$host" "$htype" "$mode" "$sname" "$auth" "$seed" "$extra" "$sni" "$fp" "$alpn")"

    jq -n \
      --arg tag "$tag" \
      --arg addr "$HP_HOST" \
      --argjson port "$HP_PORT" \
      --arg id "$user_id" \
      --arg scy "$scy" \
      --argjson stream "$stream_json" '
      {
        tag: $tag,
        protocol: "vmess",
        settings: {
          vnext: [{
            address: $addr,
            port: $port,
            users: [{ id: $id, security: $scy }]
          }]
        },
        streamSettings: $stream
      }
    '
    return 0
  fi

  local decoded_json
  decoded_json="$(b64_decode "$before_hash")"
  if ! printf '%s' "$decoded_json" | jq -e . >/dev/null 2>&1; then
    echo "VMess Base64 JSON 解码失败" >&2
    return 1
  fi

  local addr port user_id scy net tls_flag security host path sni fp alpn htype
  addr="$(printf '%s' "$decoded_json" | jq -r '.add // ""')"
  port="$(printf '%s' "$decoded_json" | jq -r '
    if (.port == null or .port == "") then 443
    else (.port | tonumber? // "") end
  ')"
  user_id="$(printf '%s' "$decoded_json" | jq -r '.id // ""')"
  scy="$(printf '%s' "$decoded_json" | jq -r '.scy // "auto"')"
  [[ -z "$scy" ]] && scy="auto"
  net="$(printf '%s' "$decoded_json" | jq -r '.net // "tcp"')"
  tls_flag="$(printf '%s' "$decoded_json" | jq -r '.tls // ""' | tr '[:upper:]' '[:lower:]')"
  security="none"
  [[ "$tls_flag" == "tls" ]] && security="tls"
  host="$(printf '%s' "$decoded_json" | jq -r '.host // ""')"
  path="$(printf '%s' "$decoded_json" | jq -r '.path // ""')"
  sni="$(printf '%s' "$decoded_json" | jq -r '.sni // ""')"
  fp="$(printf '%s' "$decoded_json" | jq -r '.fp // ""')"
  alpn="$(printf '%s' "$decoded_json" | jq -r '.alpn // ""')"
  htype="$(printf '%s' "$decoded_json" | jq -r '.type // ""')"

  if [[ -z "$addr" || -z "$user_id" ]]; then
    echo "VMess JSON 缺少 add 或 id 字段" >&2
    return 1
  fi
  if ! is_valid_port "$port"; then
    echo "VMess JSON 端口无效: ${port:-<空>}" >&2
    return 1
  fi

  local vmess_mode="" net_lower
  net_lower="$(printf '%s' "$net" | tr '[:upper:]' '[:lower:]')"
  if [[ "$net_lower" == "grpc" && "$htype" == "multi" ]]; then
    vmess_mode="multi"
  elif [[ ( "$net_lower" == "xhttp" || "$net_lower" == "splithttp" ) && -n "$htype" && "$htype" != "none" ]]; then
    vmess_mode="$htype"
  fi

  local stream_json
  stream_json="$(build_stream_settings "$net" "$security" "$addr" "$path" "$host" "$htype" "$vmess_mode" "" "" "" "" "$sni" "$fp" "$alpn")"

  jq -n \
    --arg tag "$tag" \
    --arg addr "$addr" \
    --argjson port "$port" \
    --arg id "$user_id" \
    --arg scy "$scy" \
    --argjson stream "$stream_json" '
    {
      tag: $tag,
      protocol: "vmess",
      settings: {
        vnext: [{
          address: $addr,
          port: $port,
          users: [{ id: $id, security: $scy }]
        }]
      },
      streamSettings: $stream
    }
  '
}

parse_trojan_link() {
  local link="$1" tag="${2:-proxy}"
  local rest="${link#*://}"
  rest="${rest%%#*}"
  local query=""
  if [[ "$rest" == *\?* ]]; then
    query="${rest#*\?}"
    rest="${rest%%\?*}"
  fi
  local authority="${rest%%/*}"
  if [[ "$authority" != *@* ]]; then
    echo "Trojan 链接缺少密码" >&2
    return 1
  fi
  local password hostport
  password="$(url_decode "${authority%@*}")"
  hostport="${authority##*@}"
  if ! split_host_port "$hostport" 443; then
    return 1
  fi
  if [[ -z "$HP_HOST" || -z "$password" ]]; then
    echo "Trojan 链接缺少地址或密码" >&2
    return 1
  fi

  local network security path host htype mode sname auth seed extra sni fp alpn pcs vcn pbk sid spx pqv
  network="$(get_qparam "$query" "type")"; [[ -z "$network" ]] && network="raw"
  security="$(get_qparam "$query" "security")"; [[ -z "$security" ]] && security="tls"
  path="$(get_qparam "$query" "path")"
  host="$(get_qparam "$query" "host")"
  htype="$(get_qparam "$query" "headerType")"
  mode="$(get_qparam "$query" "mode")"
  sname="$(get_qparam "$query" "serviceName")"
  auth="$(get_qparam "$query" "authority")"
  seed="$(get_qparam "$query" "seed")"
  extra="$(get_qparam "$query" "extra")"
  sni="$(get_qparam "$query" "sni")"; [[ -z "$sni" ]] && sni="$(get_qparam "$query" "peer")"
  fp="$(get_qparam "$query" "fp")"
  alpn="$(get_qparam "$query" "alpn")"
  pcs="$(get_qparam "$query" "pcs")"; [[ -z "$pcs" ]] && pcs="$(get_qparam "$query" "pinnedPeerCertSha256")"
  vcn="$(get_qparam "$query" "vcn")"; [[ -z "$vcn" ]] && vcn="$(get_qparam "$query" "verifyPeerCertByName")"
  pbk="$(get_qparam "$query" "pbk")"
  sid="$(get_qparam "$query" "sid")"
  spx="$(get_qparam "$query" "spx")"
  pqv="$(get_qparam "$query" "pqv")"

  local stream_json
  stream_json="$(build_stream_settings "$network" "$security" "$HP_HOST" "$path" "$host" "$htype" "$mode" "$sname" "$auth" "$seed" "$extra" "$sni" "$fp" "$alpn" "$pcs" "$vcn" "$pbk" "$sid" "$spx" "$pqv")"

  jq -n \
    --arg tag "$tag" \
    --arg addr "$HP_HOST" \
    --argjson port "$HP_PORT" \
    --arg pwd "$password" \
    --argjson stream "$stream_json" '
    {
      tag: $tag,
      protocol: "trojan",
      settings: {
        servers: [{ address: $addr, port: $port, password: $pwd }]
      },
      streamSettings: $stream
    }
  '
}

parse_ss_link() {
  local link="$1" tag="${2:-proxy}"
  local body="${link#*://}"
  body="${body%%#*}"
  local query=""
  if [[ "$body" == *\?* ]]; then
    query="${body#*\?}"
    body="${body%%\?*}"
  fi
  body="${body%/}"

  local method="" password="" hostport=""
  if [[ "$body" == *@* ]]; then
    local userinfo_raw="${body%@*}"
    hostport="${body##*@}"
    local userinfo_unq
    userinfo_unq="$(url_decode "$userinfo_raw")"
    if [[ "$userinfo_unq" == *:* ]]; then
      method="${userinfo_unq%%:*}"
      password="${userinfo_unq#*:}"
    else
      local decoded
      decoded="$(b64_decode "$userinfo_unq")"
      if [[ "$decoded" != *:* ]]; then
        echo "Shadowsocks userinfo 解码失败" >&2
        return 1
      fi
      method="${decoded%%:*}"
      password="${decoded#*:}"
    fi
  else
    local decoded
    decoded="$(b64_decode "$(url_decode "$body")")"
    if [[ "$decoded" != *@* ]]; then
      echo "Shadowsocks Base64 内容无效" >&2
      return 1
    fi
    local userinfo="${decoded%@*}"
    hostport="${decoded##*@}"
    if [[ "$userinfo" != *:* ]]; then
      echo "Shadowsocks 缺少加密方式或密码" >&2
      return 1
    fi
    method="${userinfo%%:*}"
    password="${userinfo#*:}"
  fi

  if ! split_host_port "$hostport" 0; then
    return 1
  fi
  if [[ -z "$HP_HOST" ]] || ! is_valid_port "$HP_PORT"; then
    echo "Shadowsocks 缺少有效的服务器地址或端口" >&2
    return 1
  fi

  local out_json
  out_json="$(jq -n \
    --arg tag "$tag" \
    --arg addr "$HP_HOST" \
    --argjson port "$HP_PORT" \
    --arg method "$method" \
    --arg pwd "$password" '
    {
      tag: $tag,
      protocol: "shadowsocks",
      settings: {
        servers: [{
          address: $addr,
          port: $port,
          method: $method,
          password: $pwd
        }]
      }
    }
  ')"

  if [[ -n "$query" ]]; then
    local net sec
    net="$(get_qparam "$query" "type")"
    sec="$(get_qparam "$query" "security")"
    if [[ -n "$net" || -n "$sec" ]]; then
      local stream_json
      stream_json="$(build_stream_settings "${net:-raw}" "${sec:-none}" "$HP_HOST" \
        "$(get_qparam "$query" "path")" \
        "$(get_qparam "$query" "host")" \
        "$(get_qparam "$query" "headerType")" \
        "$(get_qparam "$query" "mode")" \
        "$(get_qparam "$query" "serviceName")" \
        "$(get_qparam "$query" "authority")" \
        "$(get_qparam "$query" "seed")" \
        "$(get_qparam "$query" "extra")" \
        "$(get_qparam "$query" "sni")" \
        "$(get_qparam "$query" "fp")" \
        "$(get_qparam "$query" "alpn")")"
      out_json="$(printf '%s' "$out_json" | jq --argjson s "$stream_json" '. + { streamSettings: $s }')"
    fi
  fi

  printf '%s' "$out_json"
}

parse_socks_http_link() {
  local link="$1" tag="${2:-proxy}"
  local scheme="${link%%://*}"
  scheme="$(printf '%s' "$scheme" | tr '[:upper:]' '[:lower:]')"
  local proto="http" default_port=8080
  if [[ "$scheme" == "socks" || "$scheme" == "socks5" ]]; then
    proto="socks"
    default_port=1080
  elif [[ "$scheme" == "https" ]]; then
    proto="http"
    default_port=443
  fi

  local rest="${link#*://}"
  rest="${rest%%#*}"
  local query=""
  if [[ "$rest" == *\?* ]]; then
    query="${rest#*\?}"
    rest="${rest%%\?*}"
  fi
  local authority="${rest%%/*}"

  local user="" pass="" hostport="$authority"
  if [[ "$authority" == *@* ]]; then
    local uinfo="${authority%@*}"
    hostport="${authority##*@}"
    if [[ "$uinfo" == *:* ]]; then
      user="$(url_decode "${uinfo%%:*}")"
      pass="$(url_decode "${uinfo#*:}")"
    else
      user="$(url_decode "$uinfo")"
      if [[ "$proto" == "socks" ]]; then
        local dec
        dec="$(b64_decode "$user" || true)"
        if [[ "$dec" == *:* ]]; then
          user="${dec%%:*}"
          pass="${dec#*:}"
        fi
      fi
    fi
  fi

  if ! split_host_port "$hostport" "$default_port"; then
    return 1
  fi
  if [[ -z "$HP_HOST" ]]; then
    echo "${scheme} 链接缺少服务器地址" >&2
    return 1
  fi

  local out_json
  out_json="$(jq -n \
    --arg tag "$tag" \
    --arg proto "$proto" \
    --arg addr "$HP_HOST" \
    --argjson port "$HP_PORT" \
    --arg user "$user" \
    --arg pass "$pass" '
    {
      tag: $tag,
      protocol: $proto,
      settings: {
        servers: [(
          { address: $addr, port: $port }
          + (if ($user != "" or $pass != "") then { users: [{ user: $user, pass: $pass }] } else {} end)
        )]
      }
    }
  ')"

  if [[ "$scheme" == "https" ]]; then
    local stream_json
    stream_json="$(build_stream_settings "raw" "tls" "$HP_HOST" "" "" "" "" "" "" "" "" \
      "$(get_qparam "$query" "sni")" "$(get_qparam "$query" "fp")" "$(get_qparam "$query" "alpn")")"
    out_json="$(printf '%s' "$out_json" | jq --argjson s "$stream_json" '. + { streamSettings: $s }')"
  fi

  printf '%s' "$out_json"
}

parse_share_link() {
  local link="$1" tag="${2:-proxy}"
  link="${link#"${link%%[![:space:]]*}"}"
  link="${link%"${link##*[![:space:]]}"}"
  link="${link#\"}"; link="${link%\"}"
  link="${link#\'}"; link="${link%\'}"

  local lower
  lower="$(printf '%s' "$link" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    vless://*) parse_vless_link "$link" "$tag" ;;
    vmess://*) parse_vmess_link "$link" "$tag" ;;
    trojan://*) parse_trojan_link "$link" "$tag" ;;
    ss://*) parse_ss_link "$link" "$tag" ;;
    socks://*|socks5://*|http://*|https://*) parse_socks_http_link "$link" "$tag" ;;
    *)
      echo "不支持的协议前缀，当前支持: vless / vmess / trojan / ss / socks5 / http(s)" >&2
      return 1
      ;;
  esac
}

# ==================== 交互式构建入站 ====================

build_inbounds_interactive() {
  echo "" >&2
  ui_section "选择入站协议"
  ui_item "1" "SOCKS5" "本地 / 局域网代理"
  ui_item "2" "HTTP" "本地 / 局域网代理"
  ui_item "3" "SOCKS5 + HTTP" "同时开启双端口"
  ui_item "4" "VLESS" "服务端入站，支持 VLESS Encryption / TLS / REALITY"
  ui_item "5" "Shadowsocks" "服务端入站"
  ui_item "6" "Dokodemo-door" "端口转发 / 透明代理"
  echo "" >&2

  local choice
  choice="$(ask "请选择入站类型 (1-6)" "1")"
  local result="[]"

  if [[ "$choice" == "1" || "$choice" == "3" ]]; then
    local tag listen port auth="noauth" user="" pwd=""
    tag="$(ask "SOCKS5 入站 tag" "socks-in")"
    listen="$(ask "SOCKS5 监听地址" "127.0.0.1")"
    port="$(ask_port "SOCKS5 监听端口" "10808")"
    if ask_yes_no "是否启用 SOCKS5 账号密码认证" "n"; then
      auth="password"
      user="$(ask "SOCKS5 用户名" "user")"
      pwd="$(ask "SOCKS5 密码" "pass")"
    fi
    local item
    item="$(jq -n \
      --arg tag "$tag" \
      --arg listen "$listen" \
      --argjson port "$port" \
      --arg auth "$auth" \
      --arg user "$user" \
      --arg pwd "$pwd" '
      {
        tag: $tag,
        listen: $listen,
        port: $port,
        protocol: "socks",
        settings: (
          { auth: $auth, udp: true }
          + (if $auth == "password" then { accounts: [{ user: $user, pass: $pwd }] } else {} end)
        ),
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
      }
    ')"
    result="$(printf '%s' "$result" | jq --argjson i "$item" '. + [$i]')"
  fi

  if [[ "$choice" == "2" || "$choice" == "3" ]]; then
    local tag listen port use_auth="false" user="" pwd=""
    tag="$(ask "HTTP 入站 tag" "http-in")"
    listen="$(ask "HTTP 监听地址" "127.0.0.1")"
    port="$(ask_port "HTTP 监听端口" "10809")"
    if ask_yes_no "是否启用 HTTP 账号密码认证" "n"; then
      use_auth="true"
      user="$(ask "HTTP 用户名" "user")"
      pwd="$(ask "HTTP 密码" "pass")"
    fi
    local item
    item="$(jq -n \
      --arg tag "$tag" \
      --arg listen "$listen" \
      --argjson port "$port" \
      --argjson use_auth "$use_auth" \
      --arg user "$user" \
      --arg pwd "$pwd" '
      {
        tag: $tag,
        listen: $listen,
        port: $port,
        protocol: "http",
        settings: (if $use_auth then { accounts: [{ user: $user, pass: $pwd }] } else {} end),
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
      }
    ')"
    result="$(printf '%s' "$result" | jq --argjson i "$item" '. + [$i]')"
  fi

  if [[ "$choice" == "4" ]]; then
    local tag listen port user_id decryption flow network security
    tag="$(ask "VLESS 入站 tag" "vless-in")"
    listen="$(ask "VLESS 监听地址" "0.0.0.0")"
    port="$(ask_port "VLESS 监听端口" "443")"
    user_id="$(ask "客户端 UUID (回车自动生成)" "$(gen_uuid)")"
    decryption="$(ask "decryption (none 或 xray vlessenc 生成的解密串)" "none")"
    flow="$(ask "flow 流控 (如 xtls-rprx-vision，留空不启用)" "")"
    network="$(ask "传输方式 (raw/ws/grpc/xhttp)" "raw")"
    network="$(printf '%s' "$network" | tr '[:upper:]' '[:lower:]')"
    [[ "$network" == "splithttp" ]] && network="xhttp"
    security="$(ask "外层安全 (none/tls/reality)" "none")"
    security="$(printf '%s' "$security" | tr '[:upper:]' '[:lower:]')"

    local path="" sname="" cert="" key="" target="" snis="" priv_key="" sids=""
    case "$network" in
      ws) path="$(ask "WS Path" "/ws")" ;;
      xhttp) path="$(ask "XHTTP Path" "/xhttp")" ;;
      grpc) sname="$(ask "gRPC serviceName" "grpc")" ;;
    esac

    if [[ "$security" == "tls" ]]; then
      cert="$(ask "TLS 证书文件路径 (certificateFile)" "/etc/xray/fullchain.pem")"
      key="$(ask "TLS 私钥文件路径 (keyFile)" "/etc/xray/privkey.pem")"
      [[ ! -f "$cert" ]] && echo "提示：本地未检测到证书文件（仍会写入配置）: ${cert}" >&2
      [[ ! -f "$key" ]] && echo "提示：本地未检测到私钥文件（仍会写入配置）: ${key}" >&2
    elif [[ "$security" == "reality" ]]; then
      target="$(ask "REALITY 回落目标 target/dest" "www.microsoft.com:443")"
      snis="$(ask "REALITY serverNames (逗号分隔)" "${target%%:*}")"
      priv_key="$(ask "REALITY privateKey (xray x25519 生成)" "")"
      sids="$(ask "REALITY shortIds (逗号分隔，可留空)" "")"
    fi

    local item
    item="$(jq -n \
      --arg tag "$tag" \
      --arg listen "$listen" \
      --argjson port "$port" \
      --arg id "$user_id" \
      --arg dec "$decryption" \
      --arg flow "$flow" \
      --arg net "$network" \
      --arg sec "$security" \
      --arg path "$path" \
      --arg sname "$sname" \
      --arg cert "$cert" \
      --arg key "$key" \
      --arg target "$target" \
      --arg snis "$snis" \
      --arg priv "$priv_key" \
      --arg sids "$sids" '
      def csv_list: split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0));
      {
        tag: $tag,
        listen: $listen,
        port: $port,
        protocol: "vless",
        settings: {
          clients: [( { id: $id } + (if $flow != "" then { flow: $flow } else {} end) )],
          decryption: $dec
        },
        streamSettings: (
          { network: $net, security: $sec }
          + (if $net == "ws" then { wsSettings: { path: $path } }
             elif $net == "xhttp" then { xhttpSettings: { path: $path } }
             elif $net == "grpc" then { grpcSettings: { serviceName: $sname } }
             else {} end)
          + (if $sec == "tls" then {
               tlsSettings: { certificates: [{ certificateFile: $cert, keyFile: $key }] }
             }
             elif $sec == "reality" then {
               realitySettings: {
                 target: $target,
                 serverNames: ($snis | csv_list),
                 privateKey: $priv,
                 shortIds: (if ($sids | csv_list | length) > 0 then ($sids | csv_list) else [""] end)
               }
             }
             else {} end)
        ),
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
      }
    ')"
    result="$(printf '%s' "$result" | jq --argjson i "$item" '. + [$i]')"

  elif [[ "$choice" == "5" ]]; then
    local tag listen port method pwd
    tag="$(ask "Shadowsocks 入站 tag" "ss-in")"
    listen="$(ask "Shadowsocks 监听地址" "0.0.0.0")"
    port="$(ask_port "Shadowsocks 监听端口" "8388")"
    method="$(ask "加密方式" "2022-blake3-aes-128-gcm")"
    pwd="$(ask "密码 (2022 协议需 Base64 密钥)" "change-me")"
    local item
    item="$(jq -n \
      --arg tag "$tag" \
      --arg listen "$listen" \
      --argjson port "$port" \
      --arg method "$method" \
      --arg pwd "$pwd" '
      {
        tag: $tag,
        listen: $listen,
        port: $port,
        protocol: "shadowsocks",
        settings: { method: $method, password: $pwd, network: "tcp,udp" },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
      }
    ')"
    result="$(printf '%s' "$result" | jq --argjson i "$item" '. + [$i]')"

  elif [[ "$choice" == "6" ]]; then
    local tag listen port follow="false" addr="" tport=443
    tag="$(ask "Dokodemo-door 入站 tag" "dokodemo-in")"
    listen="$(ask "监听地址" "0.0.0.0")"
    port="$(ask_port "监听端口" "12345")"
    if ask_yes_no "是否为透明代理 (followRedirect)" "n"; then
      follow="true"
    else
      addr="$(ask "转发目标地址" "127.0.0.1")"
      tport="$(ask_port "转发目标端口" "443")"
    fi
    local item
    item="$(jq -n \
      --arg tag "$tag" \
      --arg listen "$listen" \
      --argjson port "$port" \
      --argjson follow "$follow" \
      --arg addr "$addr" \
      --argjson tport "$tport" '
      {
        tag: $tag,
        listen: $listen,
        port: $port,
        protocol: "dokodemo-door",
        settings: (
          { network: "tcp,udp", followRedirect: $follow }
          + (if $follow then {} else { address: $addr, port: $tport } end)
        ),
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
      }
    ')"
    result="$(printf '%s' "$result" | jq --argjson i "$item" '. + [$i]')"
  fi

  if [[ "$(printf '%s' "$result" | jq 'length')" -eq 0 ]]; then
    echo "错误：无效的入站选项。" >&2
    exit 1
  fi
  printf '%s' "$result"
}

edit_existing_inbounds_interactive() {
  echo "" >&2
  show_inbounds_summary "$INBOUNDS_JSON"
  echo "" >&2
  ui_section "入站修改方式"
  ui_item "1" "重新配置入站" "覆盖全部现有入站" "$C_YELLOW"
  ui_item "2" "追加新入站" "保留现有入站"
  ui_item "3" "删除指定序号的入站" "" "$C_RED"
  ui_item "4" "设置 / 修改入站 TLS 证书路径" "" "$C_GREEN"
  echo "" >&2
  local op
  op="$(ask "请选择操作 (1-4)" "1")"

  case "$op" in
    1)
      INBOUNDS_JSON="$(build_inbounds_interactive)"
      ;;
    2)
      local added
      added="$(build_inbounds_interactive)"
      INBOUNDS_JSON="$(jq -n --argjson old "$INBOUNDS_JSON" --argjson add "$added" '$old + $add')"
      ;;
    3)
      local count idx
      count="$(printf '%s' "$INBOUNDS_JSON" | jq 'length')"
      if (( count == 0 )); then
        echo "当前没有可删除的入站。" >&2
        return
      fi
      idx="$(ask "请输入要删除的入站序号 (1-${count})" "1")"
      if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= count )); then
        INBOUNDS_JSON="$(printf '%s' "$INBOUNDS_JSON" | jq --argjson i $((idx - 1)) 'del(.[$i])')"
        echo "已删除第 ${idx} 条入站。" >&2
      else
        echo "序号无效，未作修改。" >&2
      fi
      ;;
    4)
      configure_tls_cert_paths_interactive
      ;;
    *)
      echo "无效操作。" >&2
      exit 1
      ;;
  esac
}

# ==================== 交互式构建出站 ====================

configure_manual_outbound() {
  local tag="${1:-proxy}"
  echo "" >&2
  ui_section "手动选择出站协议"
  ui_item "1" "VLESS" "支持 VLESS Encryption / REALITY / TLS"
  ui_item "2" "VMess"
  ui_item "3" "Trojan"
  ui_item "4" "Shadowsocks"
  ui_item "5" "SOCKS5" "上游代理"
  ui_item "6" "HTTP" "上游代理"
  echo "" >&2

  local choice
  choice="$(ask "请选择出站协议 (1-6)" "1")"

  case "$choice" in
    1)
      local addr port uid enc flow net sec path="" host="" mode="" sname="" sni="" fp="" pbk="" sid="" spx=""
      addr="$(ask_required "服务器地址")"
      port="$(ask_port "服务器端口" "443")"
      uid="$(ask_required "UUID")"
      enc="$(ask "encryption (none 或 mlkem768x25519plus...)" "none")"
      flow="$(ask "flow (如 xtls-rprx-vision，留空不启用)" "")"
      net="$(ask "传输方式 (raw/ws/grpc/xhttp)" "raw")"
      net="$(printf '%s' "$net" | tr '[:upper:]' '[:lower:]')"
      [[ "$net" == "splithttp" ]] && net="xhttp"
      sec="$(ask "外层安全 (none/tls/reality)" "none")"
      sec="$(printf '%s' "$sec" | tr '[:upper:]' '[:lower:]')"

      if [[ "$net" == "ws" || "$net" == "xhttp" || "$net" == "httpupgrade" ]]; then
        path="$(ask "Path" "/")"
        host="$(ask "Host (可留空)" "")"
        [[ "$net" == "xhttp" ]] && mode="$(ask "XHTTP mode (auto/packet-up/stream-up/stream-one，可留空)" "")"
      elif [[ "$net" == "grpc" ]]; then
        sname="$(ask "gRPC serviceName" "")"
      fi

      if [[ "$sec" == "tls" ]]; then
        sni="$(ask "SNI" "$addr")"
        fp="$(ask "uTLS 指纹 (如 chrome，可留空)" "chrome")"
      elif [[ "$sec" == "reality" ]]; then
        sni="$(ask "REALITY serverName (SNI)" "www.microsoft.com")"
        fp="$(ask "uTLS 指纹" "chrome")"
        pbk="$(ask_required "REALITY publicKey")"
        sid="$(ask "REALITY shortId (可留空)" "")"
        spx="$(ask "REALITY spiderX (可留空)" "")"
      fi

      local stream_json
      stream_json="$(build_stream_settings "$net" "$sec" "$addr" "$path" "$host" "" "$mode" "$sname" "" "" "" "$sni" "$fp" "" "" "" "$pbk" "$sid" "$spx" "")"
      jq -n \
        --arg tag "$tag" \
        --arg addr "$addr" \
        --argjson port "$port" \
        --arg id "$uid" \
        --arg enc "$enc" \
        --arg flow "$flow" \
        --argjson stream "$stream_json" '
        {
          tag: $tag,
          protocol: "vless",
          settings: (
            { address: $addr, port: $port, id: $id, encryption: $enc }
            + (if $flow != "" then { flow: $flow } else {} end)
          ),
          streamSettings: $stream
        }
      '
      ;;

    2)
      local addr port uid scy net sec path="" host="" sname="" sni=""
      addr="$(ask_required "服务器地址")"
      port="$(ask_port "服务器端口" "443")"
      uid="$(ask_required "UUID")"
      scy="$(ask "加密方式 (auto/aes-128-gcm/chacha20-poly1305/none)" "auto")"
      net="$(ask "传输方式 (tcp/ws/grpc)" "ws")"
      net="$(printf '%s' "$net" | tr '[:upper:]' '[:lower:]')"
      sec="$(ask "外层安全 (none/tls)" "tls")"
      sec="$(printf '%s' "$sec" | tr '[:upper:]' '[:lower:]')"
      if [[ "$net" == "ws" ]]; then
        path="$(ask "WS Path" "/")"
        host="$(ask "WS Host" "$addr")"
      elif [[ "$net" == "grpc" ]]; then
        sname="$(ask "gRPC serviceName" "")"
      fi
      [[ "$sec" == "tls" ]] && sni="$(ask "SNI" "$addr")"

      local stream_json
      stream_json="$(build_stream_settings "$net" "$sec" "$addr" "$path" "$host" "" "" "$sname" "" "" "" "$sni")"
      jq -n \
        --arg tag "$tag" \
        --arg addr "$addr" \
        --argjson port "$port" \
        --arg id "$uid" \
        --arg scy "$scy" \
        --argjson stream "$stream_json" '
        {
          tag: $tag,
          protocol: "vmess",
          settings: { vnext: [{ address: $addr, port: $port, users: [{ id: $id, security: $scy }] }] },
          streamSettings: $stream
        }
      '
      ;;

    3)
      local addr port pwd net sec path="" host="" sname="" sni="" fp="" pbk="" sid=""
      addr="$(ask_required "服务器地址")"
      port="$(ask_port "服务器端口" "443")"
      pwd="$(ask_required "Trojan 密码")"
      net="$(ask "传输方式 (raw/ws/grpc)" "raw")"
      net="$(printf '%s' "$net" | tr '[:upper:]' '[:lower:]')"
      sec="$(ask "外层安全 (tls/reality/none)" "tls")"
      sec="$(printf '%s' "$sec" | tr '[:upper:]' '[:lower:]')"

      if [[ "$net" == "ws" ]]; then
        path="$(ask "WS Path" "/")"
        host="$(ask "WS Host (可留空)" "")"
      elif [[ "$net" == "grpc" ]]; then
        sname="$(ask "gRPC serviceName" "")"
      fi

      if [[ "$sec" == "tls" ]]; then
        sni="$(ask "SNI" "$addr")"
        fp="$(ask "uTLS 指纹" "chrome")"
      elif [[ "$sec" == "reality" ]]; then
        sni="$(ask "REALITY SNI" "www.microsoft.com")"
        pbk="$(ask_required "REALITY publicKey")"
        sid="$(ask "REALITY shortId" "")"
        fp="$(ask "uTLS 指纹" "chrome")"
      fi

      local stream_json
      stream_json="$(build_stream_settings "$net" "$sec" "$addr" "$path" "$host" "" "" "$sname" "" "" "" "$sni" "$fp" "" "" "" "$pbk" "$sid")"
      jq -n \
        --arg tag "$tag" \
        --arg addr "$addr" \
        --argjson port "$port" \
        --arg pwd "$pwd" \
        --argjson stream "$stream_json" '
        {
          tag: $tag,
          protocol: "trojan",
          settings: { servers: [{ address: $addr, port: $port, password: $pwd }] },
          streamSettings: $stream
        }
      '
      ;;

    4)
      local addr port method pwd
      addr="$(ask_required "服务器地址")"
      port="$(ask_port "服务器端口" "8388")"
      method="$(ask "加密方式" "2022-blake3-aes-128-gcm")"
      pwd="$(ask_required "密码")"
      jq -n \
        --arg tag "$tag" \
        --arg addr "$addr" \
        --argjson port "$port" \
        --arg method "$method" \
        --arg pwd "$pwd" '
        {
          tag: $tag,
          protocol: "shadowsocks",
          settings: { servers: [{ address: $addr, port: $port, method: $method, password: $pwd }] }
        }
      '
      ;;

    5|6)
      local proto="socks" proto_upper="SOCKS" dport=1080
      [[ "$choice" == "6" ]] && { proto="http"; proto_upper="HTTP"; dport=8080; }
      local addr port user="" pass=""
      addr="$(ask_required "${proto_upper} 代理地址")"
      port="$(ask_port "${proto_upper} 代理端口" "$dport")"
      if ask_yes_no "上游代理是否需要账号密码" "n"; then
        user="$(ask_required "用户名")"
        pass="$(ask_required "密码")"
      fi
      jq -n \
        --arg tag "$tag" \
        --arg proto "$proto" \
        --arg addr "$addr" \
        --argjson port "$port" \
        --arg user "$user" \
        --arg pass "$pass" '
        {
          tag: $tag,
          protocol: $proto,
          settings: {
            servers: [(
              { address: $addr, port: $port }
              + (if ($user != "" or $pass != "") then { users: [{ user: $user, pass: $pass }] } else {} end)
            )]
          }
        }
      '
      ;;

    *)
      echo "错误：无效的出站协议选项。" >&2
      exit 1
      ;;
  esac
}

build_single_outbound_interactive() {
  local default_tag="${1:-proxy}"
  echo "" >&2
  ui_section "选择出站方式"
  ui_item "1" "直连 (freedom)" "直接发出流量" "$C_GREEN"
  ui_item "2" "协议分享链接解析" "vless / vmess / trojan / ss / socks5 / http"
  ui_item "3" "手动配置代理协议出站" "逐步输入服务器与传输参数"
  echo "" >&2

  local choice
  choice="$(ask "请选择出站方式 (1-3)" "2")"

  case "$choice" in
    1)
      local tag strategy direct_default="direct"
      if [[ "$(printf '%s' "$OUTBOUNDS_JSON" | jq '[.[] | select(.tag == "direct")] | length')" -gt 0 ]]; then
        direct_default="$default_tag"
      fi
      tag="$(ask "出站 tag" "$direct_default")"
      strategy="$(ask "域名解析策略 (AsIs / UseIP / UseIPv4 / UseIPv6)" "AsIs")"
      jq -n --arg tag "$tag" --arg s "$strategy" \
        '{ tag: $tag, protocol: "freedom", settings: { domainStrategy: $s } }'
      ;;
    2)
      local tag link proxy_out
      tag="$(ask "出站 tag" "$default_tag")"
      while true; do
        link="$(ask "请粘贴协议分享链接")"
        if proxy_out="$(parse_share_link "$link" "$tag")"; then
          echo "链接解析成功。" >&2
          printf '%s' "$proxy_out"
          return 0
        fi
        echo "请检查链接格式后重试。" >&2
      done
      ;;
    3)
      local tag
      tag="$(ask "出站 tag" "$default_tag")"
      configure_manual_outbound "$tag"
      ;;
    *)
      echo "错误：无效的出站选项。" >&2
      exit 1
      ;;
  esac
}

configure_full_outbounds_interactive() {
  local primary
  primary="$(build_single_outbound_interactive "proxy")"
  local proto
  proto="$(printf '%s' "$primary" | jq -r '.protocol')"

  if [[ "$proto" == "freedom" ]]; then
    OUTBOUNDS_JSON="$(jq -n --argjson p "$primary" '
      [ $p ] + (if $p.tag != "block" then [{ tag: "block", protocol: "blackhole" }] else [] end)
    ')"
  else
    OUTBOUNDS_JSON="$(jq -n --argjson p "$primary" '
      [ $p ]
      + (if $p.tag != "direct" then [{ tag: "direct", protocol: "freedom" }] else [] end)
      + (if $p.tag != "block" then [{ tag: "block", protocol: "blackhole" }] else [] end)
    ')"
  fi
}

set_primary_outbound() {
  local idx="$1"
  local count
  count="$(printf '%s' "$OUTBOUNDS_JSON" | jq 'length')"
  if (( count == 0 )); then
    echo "错误：当前配置中没有出站，无法切换默认主出站。" >&2
    return 1
  fi
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > count )); then
    echo "错误：出站序号 ${idx} 无效（当前共 ${count} 条出站）。" >&2
    return 1
  fi

  local zero_idx=$((idx - 1))
  local tag
  tag="$(printf '%s' "$OUTBOUNDS_JSON" | jq -r --argjson i "$zero_idx" '.[$i].tag // "-"')"

  if (( idx == 1 )); then
    echo "第 1 条出站 (tag=${tag}) 当前已是默认主出站，无需切换。" >&2
    return 0
  fi

  OUTBOUNDS_JSON="$(printf '%s' "$OUTBOUNDS_JSON" | jq --argjson i "$zero_idx" '
    [.[$i]] + del(.[$i])
  ')"
  echo "已将第 ${idx} 条出站 (tag=${tag}) 设为默认主出站（第 1 条）。" >&2
}

edit_existing_outbounds_interactive() {
  echo "" >&2
  show_outbounds_summary "$OUTBOUNDS_JSON"
  echo "" >&2
  ui_section "出站修改方式"
  ui_item "1" "仅替换第 1 条主出站" "保留其余出站与 tag 结构"
  ui_item "2" "重新配置全部出站" "重置为 主出站 + direct + block" "$C_YELLOW"
  ui_item "3" "追加一条新出站" "保留现有出站"
  ui_item "4" "删除指定序号的出站" "" "$C_RED"
  ui_item "5" "切换默认主出站" "将指定序号出站置顶到第 1 条" "$C_GREEN"
  echo "" >&2
  local op
  op="$(ask "请选择操作 (1-5)" "1")"

  case "$op" in
    1)
      local cur_tag new_out count
      count="$(printf '%s' "$OUTBOUNDS_JSON" | jq 'length')"
      cur_tag="$(printf '%s' "$OUTBOUNDS_JSON" | jq -r '.[0].tag // "proxy"')"
      new_out="$(build_single_outbound_interactive "$cur_tag")"
      if (( count == 0 )); then
        OUTBOUNDS_JSON="$(jq -n --argjson n "$new_out" '[$n]')"
      else
        OUTBOUNDS_JSON="$(printf '%s' "$OUTBOUNDS_JSON" | jq --argjson n "$new_out" '.[0] = $n')"
      fi
      ;;
    2)
      configure_full_outbounds_interactive
      ;;
    3)
      local count new_out
      count="$(printf '%s' "$OUTBOUNDS_JSON" | jq 'length')"
      new_out="$(build_single_outbound_interactive "proxy-$((count + 1))")"
      OUTBOUNDS_JSON="$(printf '%s' "$OUTBOUNDS_JSON" | jq --argjson n "$new_out" '. + [$n]')"
      ;;
    4)
      local count idx
      count="$(printf '%s' "$OUTBOUNDS_JSON" | jq 'length')"
      if (( count == 0 )); then
        echo "当前没有可删除的出站。" >&2
        return
      fi
      idx="$(ask "请输入要删除的出站序号 (1-${count})" "1")"
      if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= count )); then
        OUTBOUNDS_JSON="$(printf '%s' "$OUTBOUNDS_JSON" | jq --argjson i $((idx - 1)) 'del(.[$i])')"
        echo "已删除第 ${idx} 条出站。" >&2
      else
        echo "序号无效，未作修改。" >&2
      fi
      ;;
    5)
      local count idx
      count="$(printf '%s' "$OUTBOUNDS_JSON" | jq 'length')"
      if (( count < 2 )); then
        echo "当前不足 2 条出站，无需切换。" >&2
        return
      fi
      idx="$(ask "请输入要设为默认主出站的序号 (1-${count})" "2")"
      set_primary_outbound "$idx"
      ;;
    *)
      echo "无效操作。" >&2
      exit 1
      ;;
  esac
}

# ==================== 写入与校验 ====================

copy_file_mode() {
  local src="$1"
  local dst="$2"
  local fallback="${3:-644}"
  if ! chmod --reference="$src" "$dst" 2>/dev/null; then
    local mode=""
    mode="$(stat -c '%a' "$src" 2>/dev/null || stat -f '%Lp' "$src" 2>/dev/null || true)"
    if [[ -n "$mode" ]]; then
      chmod "$mode" "$dst" 2>/dev/null || chmod "$fallback" "$dst"
    else
      chmod "$fallback" "$dst"
    fi
  fi
}

update_inbound_endpoint() {
  local idx="$1"
  local set_listen="$2"
  local listen_val="$3"
  local set_port="$4"
  local port_val="$5"

  local count
  count="$(printf '%s' "$INBOUNDS_JSON" | jq 'length')"
  if (( count == 0 )); then
    echo "错误：当前配置中没有入站，无法修改监听地址或端口（如需新建请同时传入 --in-proto）。" >&2
    return 1
  fi
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > count )); then
    echo "错误：入站序号 ${idx} 无效（当前共 ${count} 条入站）。" >&2
    return 1
  fi

  local zero_idx=$((idx - 1))
  INBOUNDS_JSON="$(printf '%s' "$INBOUNDS_JSON" | jq \
    --argjson i "$zero_idx" \
    --argjson set_listen "$set_listen" \
    --arg listen "$listen_val" \
    --argjson set_port "$set_port" \
    --argjson port "${port_val:-0}" '
    .[$i] |= (
      (if $set_listen then .listen = $listen else . end)
      | (if $set_port then .port = $port else . end)
    )
  ')"
  echo "已更新第 ${idx} 条入站的监听设置。" >&2
}

save_config() {
  local output="$1"
  local allow_force="${2:-false}"
  local final_json

  if [[ -n "$BASE_CONFIG_JSON" ]]; then
    final_json="$(printf '%s' "$BASE_CONFIG_JSON" | jq \
      --argjson inbounds "$INBOUNDS_JSON" \
      --argjson outbounds "$OUTBOUNDS_JSON" \
      '.inbounds = $inbounds | .outbounds = $outbounds')"
  else
    final_json="$(jq -n \
      --argjson inbounds "$INBOUNDS_JSON" \
      --argjson outbounds "$OUTBOUNDS_JSON" '
      {
        log: { loglevel: "warning" },
        inbounds: $inbounds,
        outbounds: $outbounds
      }
    ')"
  fi

  if [[ -f "$output" ]] && jq -e --argjson new "$final_json" '. == $new' "$output" >/dev/null 2>&1; then
    echo "配置内容未发生变化，跳过写入。"
    return 0
  fi

  local output_dir tmp_file
  output_dir="$(dirname "$output")"
  tmp_file="$(mktemp "${output_dir}/.xray_config.tmp.XXXXXX.json" 2>/dev/null || mktemp "${output_dir}/.xray_config.tmp.XXXXXX")"
  if ! printf '%s\n' "$final_json" > "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi

  if ! validate_with_xray "$tmp_file" "$allow_force" "$output"; then
    rm -f "$tmp_file"
    return 1
  fi

  if [[ -f "$output" ]]; then
    copy_file_mode "$output" "$tmp_file" "644"
    if ! chown --reference="$output" "$tmp_file" 2>/dev/null; then
      local owner=""
      owner="$(stat -c '%u:%g' "$output" 2>/dev/null || stat -f '%u:%g' "$output" 2>/dev/null || true)"
      [[ -n "$owner" ]] && chown "$owner" "$tmp_file" 2>/dev/null || true
    fi
  else
    chmod 644 "$tmp_file"
  fi

  if ! mv -f "$tmp_file" "$output"; then
    rm -f "$tmp_file"
    echo "错误：写入配置文件失败：${output}" >&2
    return 1
  fi
  echo "已成功写入配置：${output}"

  if [[ "$(id -u 2>/dev/null || echo 1)" -eq 0 ]]; then
    local cur_mode=""
    cur_mode="$(stat -c '%a' "$output" 2>/dev/null || stat -f '%Lp' "$output" 2>/dev/null || true)"
    if [[ "$cur_mode" == "600" ]]; then
      echo "提示：${output} 当前权限为 600；若 xray.service 以非 root 用户运行，请执行 chmod 644 ${output}" >&2
    fi
  fi
}

validate_with_xray() {
  local cfg="$1"
  local allow_force="${2:-false}"
  local target_label="${3:-$cfg}"
  if command -v xray >/dev/null 2>&1; then
    echo ""
    echo "检测到本地 xray，正在执行写入前配置校验..."
    if xray run -test -format json -c "$cfg"; then
      echo "校验通过。"
      return 0
    fi
    if [[ "$allow_force" == "true" && -t 0 ]]; then
      if ask_yes_no "警告：xray 配置校验未通过，是否仍强制写入 ${target_label}" "n"; then
        return 0
      fi
    fi
    echo "错误：xray 配置校验未通过，已取消写入（原配置未被修改）。" >&2
    return 1
  else
    echo "未在 PATH 中检测到 xray，已跳过自动校验。"
    return 0
  fi
}

# ==================== 脚本自更新 ====================

DEFAULT_UPDATE_URL="https://raw.githubusercontent.com/Henry00123/xray-gen/main/xray_gen.sh"

resolve_script_path() {
  local src="${BASH_SOURCE[0]:-$0}"
  [[ -n "$src" ]] || return 1
  while [[ -L "$src" ]]; do
    local dir target
    dir="$(cd -P "$(dirname "$src")" && pwd)" || return 1
    target="$(readlink "$src")" || return 1
    [[ "$target" != /* ]] && target="${dir}/${target}"
    src="$target"
  done
  local dir
  dir="$(cd -P "$(dirname "$src")" && pwd)" || return 1
  printf '%s/%s' "$dir" "$(basename "$src")"
}

files_identical() {
  if command -v cmp >/dev/null 2>&1; then
    cmp -s "$1" "$2"
  elif command -v diff >/dev/null 2>&1; then
    diff -q "$1" "$2" >/dev/null 2>&1
  else
    return 1
  fi
}

download_to_file() {
  local url="$1"
  local dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 15 --max-time 60 -o "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --no-cache --timeout=15 -O "$dest" "$url"
  else
    echo "错误：未找到 curl 或 wget，无法下载更新。" >&2
    return 1
  fi
}

self_update() {
  local url="${1:-${XRAY_GEN_UPDATE_URL:-$DEFAULT_UPDATE_URL}}"
  if [[ -z "$url" ]]; then
    echo "错误：更新地址不能为空。" >&2
    return 1
  fi

  local target_path
  if ! target_path="$(resolve_script_path)" || [[ ! -f "$target_path" ]]; then
    echo "错误：无法定位当前脚本文件，请以本地文件方式运行后再执行更新。" >&2
    return 1
  fi

  local target_dir tmp_file
  target_dir="$(dirname "$target_path")"
  if ! tmp_file="$(mktemp "${target_dir}/.xray_gen.sh.tmp.XXXXXX" 2>/dev/null)"; then
    echo "错误：无法在 ${target_dir} 创建临时文件，请检查目录写权限（如需要请使用 sudo）。" >&2
    return 1
  fi

  echo "正在检查脚本更新: ${url}"
  if ! download_to_file "$url" "$tmp_file"; then
    rm -f "$tmp_file"
    echo "错误：下载更新失败，请检查网络连接或使用 --update-url / XRAY_GEN_UPDATE_URL 指定镜像地址。" >&2
    return 1
  fi

  local first_line=""
  IFS= read -r first_line < "$tmp_file" || true
  if [[ ! -s "$tmp_file" || "$first_line" != "#!/usr/bin/env bash" ]]; then
    rm -f "$tmp_file"
    echo "错误：下载的内容不是有效的 xray_gen.sh 脚本（文件头校验失败）。" >&2
    return 1
  fi

  if ! bash -n "$tmp_file"; then
    rm -f "$tmp_file"
    echo "错误：下载的脚本未通过 bash -n 语法校验，已取消更新。" >&2
    return 1
  fi

  if files_identical "$target_path" "$tmp_file"; then
    rm -f "$tmp_file"
    echo "当前脚本已是最新版本，无需更新。"
    return 0
  fi

  copy_file_mode "$target_path" "$tmp_file" "755"
  chmod +x "$tmp_file" 2>/dev/null || true

  if ! mv -f "$tmp_file" "$target_path"; then
    rm -f "$tmp_file"
    echo "错误：替换脚本失败，请检查文件写权限。" >&2
    return 1
  fi

  echo "脚本已更新：${target_path}"
}

# ==================== Xray 安装与状态监测 ====================

XRAY_INSTALL_URL="${XRAY_INSTALL_URL:-https://github.com/XTLS/Xray-install/raw/main/install-release.sh}"

run_privileged() {
  if [[ "$(id -u 2>/dev/null || echo 1)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "错误：该操作需要 root 权限，请切换为 root 或安装 sudo 后重试。" >&2
    return 1
  fi
}

download_xray_installer() {
  local url="$1"
  local dest="$2"
  if [[ "$url" == file://* ]]; then
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL -o "$dest" "$url"
      return $?
    fi
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q --no-cache --timeout=30 -O "$dest" "$url"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 15 --max-time 120 -o "$dest" "$url"
  else
    echo "错误：未找到 wget 或 curl，无法下载 Xray 安装脚本。" >&2
    return 1
  fi
}

get_xray_version() {
  if ! command -v xray >/dev/null 2>&1; then
    return 1
  fi
  local raw first_line ver
  raw="$(xray version 2>/dev/null || true)"
  first_line="${raw%%$'\n'*}"
  ver="$(printf '%s' "$first_line" | awk '{print $2}')"
  printf '%s' "${ver:-unknown}"
}

get_xray_brief_status() {
  local ver=""
  if ! ver="$(get_xray_version)"; then
    printf '%s未安装%s' "$C_YELLOW" "$C_RESET"
    return 0
  fi

  local state_text=""
  if command -v systemctl >/dev/null 2>&1; then
    local active=""
    active="$(systemctl is-active xray 2>/dev/null || true)"
    case "$active" in
      active)
        state_text="${C_GREEN}运行中${C_RESET}"
        ;;
      activating|reloading)
        state_text="${C_YELLOW}启动中 (${active})${C_RESET}"
        ;;
      failed)
        state_text="${C_RED}异常退出 (failed)${C_RESET}"
        ;;
      inactive)
        state_text="${C_YELLOW}未运行 (inactive)${C_RESET}"
        ;;
      *)
        if command -v pgrep >/dev/null 2>&1 && pgrep -x xray >/dev/null 2>&1; then
          state_text="${C_GREEN}运行中 (进程)${C_RESET}"
        else
          state_text="${C_DIM}未运行 (${active:-未注册服务})${C_RESET}"
        fi
        ;;
    esac
  elif command -v pgrep >/dev/null 2>&1 && pgrep -x xray >/dev/null 2>&1; then
    state_text="${C_GREEN}运行中${C_RESET}"
  else
    state_text="${C_DIM}未运行${C_RESET}"
  fi

  printf '%s%s%s %s·%s %s' "$C_BOLD" "$ver" "$C_RESET" "$C_DIM" "$C_RESET" "$state_text"
}

install_xray() {
  local action="${1:-install}"
  shift || true

  local tmp_script
  tmp_script="$(mktemp)"
  echo "正在下载 Xray 官方安装脚本: ${XRAY_INSTALL_URL}"
  if ! download_xray_installer "$XRAY_INSTALL_URL" "$tmp_script"; then
    rm -f "$tmp_script"
    echo "错误：下载 Xray 安装脚本失败，请检查网络连接（也可通过环境变量 XRAY_INSTALL_URL 指定镜像地址）。" >&2
    return 1
  fi

  if [[ ! -s "$tmp_script" ]] || ! bash -n "$tmp_script"; then
    rm -f "$tmp_script"
    echo "错误：下载的安装脚本为空或未通过 bash -n 语法校验，已取消执行。" >&2
    return 1
  fi

  echo "正在执行 Xray 官方脚本: ${action}${*:+ $*}"
  local rc=0
  run_privileged bash "$tmp_script" "$action" "$@" || rc=$?
  rm -f "$tmp_script"

  if (( rc != 0 )); then
    echo "错误：Xray 官方脚本执行失败（退出码: ${rc}）。" >&2
    return "$rc"
  fi

  if [[ "$action" == "install" ]]; then
    local ver=""
    if ver="$(get_xray_version)"; then
      echo "Xray 安装/更新完成，当前版本：${ver}"
    else
      echo "Xray 安装脚本执行完成。"
    fi
  else
    echo "Xray 操作 (${action}) 执行完成。"
  fi
}

manage_xray_install_interactive() {
  echo "" >&2
  ui_header "Xray 安装与卸载" "$(get_xray_brief_status)"
  ui_section "选择操作"
  ui_item "1" "安装 / 更新 Xray" "使用官方默认配置 (install)" "$C_GREEN"
  ui_item "2" "安装 / 更新 Xray (root 运行)" "以 root 用户运行服务 (install -u root)" "$C_CYAN"
  ui_item "3" "卸载 Xray" "执行官方卸载命令 (remove)" "$C_RED"
  ui_item "0" "返回" "" "$C_DIM"
  echo "" >&2

  local op
  op="$(ask "请选择 (0-3)" "1")"
  case "$op" in
    1)
      install_xray install
      ;;
    2)
      install_xray install -u root
      ;;
    3)
      if ask_yes_no "确认卸载 Xray" "n"; then
        install_xray remove
      else
        echo "已取消卸载。" >&2
      fi
      ;;
    0)
      return 0
      ;;
    *)
      echo "无效选项。" >&2
      return 1
      ;;
  esac
}

control_xray_service() {
  local action="$1"
  case "$action" in
    start|stop|restart) ;;
    *)
      echo "错误：不支持的服务操作: ${action}（仅支持 start / stop / restart）。" >&2
      return 1
      ;;
  esac

  if ! command -v systemctl >/dev/null 2>&1; then
    echo "错误：当前系统未检测到 systemctl，无法通过 systemd 控制 Xray 服务。" >&2
    return 1
  fi

  echo "正在执行: systemctl ${action} xray ..."
  local rc=0
  run_privileged systemctl "$action" xray || rc=$?

  local state=""
  state="$(systemctl is-active xray 2>/dev/null || true)"
  if (( rc == 0 )); then
    echo "执行完成，当前服务状态：${state:-unknown}"
  else
    echo "错误：systemctl ${action} xray 执行失败（当前状态：${state:-unknown}）。" >&2
    if command -v journalctl >/dev/null 2>&1; then
      echo "--- 最近日志 (journalctl -u xray -n 10) ---" >&2
      local err_logs=""
      err_logs="$(journalctl -u xray -n 10 --no-pager 2>/dev/null || true)"
      [[ -n "$err_logs" ]] && printf '%s\n' "$err_logs" >&2
    fi
    return "$rc"
  fi
}

show_xray_status() {
  local cfg_path="${1:-./config.json}"
  ui_header "Xray 状态监测"

  ui_section "安装信息"
  if command -v xray >/dev/null 2>&1; then
    local xray_bin raw_ver first_line
    xray_bin="$(command -v xray)"
    raw_ver="$(xray version 2>/dev/null || true)"
    first_line="${raw_ver%%$'\n'*}"
    printf '  %s路径:%s %s\n' "$C_DIM" "$C_RESET" "$xray_bin" >&2
    printf '  %s版本:%s %s%s%s\n' "$C_DIM" "$C_RESET" "$C_BOLD" "${first_line:-unknown}" "$C_RESET" >&2
  else
    printf '  %s未检测到 xray 可执行文件（可运行 ./xray_gen.sh --install-xray 安装）%s\n' "$C_YELLOW" "$C_RESET" >&2
  fi

  echo "" >&2
  ui_section "服务运行状态"
  if command -v systemctl >/dev/null 2>&1; then
    local active enabled main_pid svc_user started_at active_color="$C_YELLOW"
    active="$(systemctl is-active xray 2>/dev/null || true)"
    enabled="$(systemctl is-enabled xray 2>/dev/null || true)"
    main_pid="$(systemctl show xray -p MainPID --value 2>/dev/null || true)"
    svc_user="$(systemctl show xray -p User --value 2>/dev/null || true)"
    started_at="$(systemctl show xray -p ExecMainStartTimestamp --value 2>/dev/null || true)"
    [[ "$active" == "active" ]] && active_color="$C_GREEN"
    [[ "$active" == "failed" ]] && active_color="$C_RED"
    printf '  %s运行状态:%s %s%s%s%s\n' "$C_DIM" "$C_RESET" "$C_BOLD" "$active_color" "${active:-unknown}" "$C_RESET" >&2
    printf '  %s开机自启:%s %s\n' "$C_DIM" "$C_RESET" "${enabled:-未注册}" >&2
    [[ -n "$main_pid" && "$main_pid" != "0" ]] && printf '  %s主进程PID:%s %s\n' "$C_DIM" "$C_RESET" "$main_pid" >&2
    [[ -n "$svc_user" ]] && printf '  %s运行用户:%s %s\n' "$C_DIM" "$C_RESET" "$svc_user" >&2
    [[ -n "$started_at" ]] && printf '  %s启动时间:%s %s\n' "$C_DIM" "$C_RESET" "$started_at" >&2
  elif command -v pgrep >/dev/null 2>&1; then
    local pids=""
    pids="$(pgrep -x xray 2>/dev/null | tr '\n' ' ' || true)"
    if [[ -n "$pids" ]]; then
      printf '  %s运行状态:%s %s运行中%s (PID: %s)\n' "$C_DIM" "$C_RESET" "$C_GREEN" "$C_RESET" "${pids% }" >&2
    else
      printf '  %s运行状态:%s %s未运行%s (当前环境无 systemctl)\n' "$C_DIM" "$C_RESET" "$C_YELLOW" "$C_RESET" >&2
    fi
  else
    printf '  %s当前环境无 systemctl / pgrep，无法检测服务进程%s\n' "$C_DIM" "$C_RESET" >&2
  fi

  echo "" >&2
  ui_section "配置文件检查"
  local check_cfg="$cfg_path"
  if [[ ! -f "$check_cfg" && -f "/usr/local/etc/xray/config.json" ]]; then
    check_cfg="/usr/local/etc/xray/config.json"
  fi
  if [[ -f "$check_cfg" ]]; then
    local mode="" owner=""
    mode="$(stat -c '%a' "$check_cfg" 2>/dev/null || stat -f '%Lp' "$check_cfg" 2>/dev/null || true)"
    owner="$(stat -c '%U:%G' "$check_cfg" 2>/dev/null || stat -f '%Su:%Sg' "$check_cfg" 2>/dev/null || true)"
    printf '  %s文件:%s %s %s(权限: %s, 属主: %s)%s\n' "$C_DIM" "$C_RESET" "$check_cfg" "$C_DIM" "${mode:--}" "${owner:--}" "$C_RESET" >&2
    if command -v xray >/dev/null 2>&1; then
      if xray run -test -format json -c "$check_cfg" >/dev/null 2>&1; then
        printf '  %s校验:%s %s通过 (xray run -test)%s\n' "$C_DIM" "$C_RESET" "$C_GREEN" "$C_RESET" >&2
      else
        printf '  %s校验:%s %s未通过（请运行 xray run -test -c %s 查看详情）%s\n' "$C_DIM" "$C_RESET" "$C_RED" "$check_cfg" "$C_RESET" >&2
      fi
    fi
  else
    printf '  %s未找到配置文件 (%s)%s\n' "$C_DIM" "$cfg_path" "$C_RESET" >&2
  fi

  echo "" >&2
  ui_section "监听端口"
  local ports=""
  if command -v ss >/dev/null 2>&1; then
    ports="$(ss -tulnp 2>/dev/null | grep -i 'xray' || true)"
  elif command -v netstat >/dev/null 2>&1; then
    ports="$(netstat -tulnp 2>/dev/null | grep -i 'xray' || true)"
  fi
  if [[ -n "$ports" ]]; then
    printf '%s\n' "$ports" | sed 's/^/  /' >&2
  else
    printf '  %s未检测到 xray 监听端口（非 root 用户可能需要 sudo 才能显示进程名）%s\n' "$C_DIM" "$C_RESET" >&2
  fi

  echo "" >&2
  ui_section "最近日志" "(最多 15 条)"
  local logs=""
  if command -v journalctl >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
    logs="$(journalctl -u xray -n 15 --no-pager 2>/dev/null || true)"
  elif [[ -r /var/log/xray/error.log ]]; then
    logs="$(tail -n 15 /var/log/xray/error.log 2>/dev/null || true)"
  fi
  if [[ -n "$logs" ]]; then
    printf '%s\n' "$logs" | sed 's/^/  /' >&2
  else
    printf '  %s暂无可用日志（非 root 用户可能需要 sudo 查看 journalctl）%s\n' "$C_DIM" "$C_RESET" >&2
  fi
  ui_hr
}

monitor_xray_interactive() {
  local cfg_path="${1:-./config.json}"
  while true; do
    show_xray_status "$cfg_path"
    echo "" >&2
    ui_section "Xray 服务操作"
    ui_item "1" "刷新状态"
    ui_item "2" "启动 Xray" "systemctl start xray" "$C_GREEN"
    ui_item "3" "重启 Xray" "systemctl restart xray" "$C_YELLOW"
    ui_item "4" "停止 Xray" "systemctl stop xray" "$C_RED"
    ui_item "5" "安装 / 更新 / 卸载 Xray" "执行官方 install-release.sh"
    ui_item "0" "退出" "" "$C_DIM"
    echo "" >&2

    local op
    op="$(ask "请选择 (0-5)" "0")"
    case "$op" in
      1) continue ;;
      2) control_xray_service start || true ;;
      3) control_xray_service restart || true ;;
      4) control_xray_service stop || true ;;
      5) manage_xray_install_interactive || true ;;
      0) return 0 ;;
      *) echo "无效选项。" >&2 ;;
    esac
  done
}

# ==================== 主流程与命令行参数 ====================

usage() {
  cat <<'EOF'
用法: ./xray_gen.sh [选项]

无参数运行时自动检查当前目录 ./config.json：
  - 若存在：展示 Xray 状态概览及当前入站/出站摘要，进入主菜单
  - 若不存在：展示 Xray 状态概览及简明主菜单（可新建配置、安装 Xray 或监测状态）

选项:
  -c, -o, --output <file>   指定配置文件路径 (默认: ./config.json)
  -s, --show                读取并展示当前配置文件的入站与出站信息后退出
      --in-proto <proto>    快捷模式重建入站协议: socks 或 http（单独传入时仅修改入站）
      --listen <addr>       入站监听地址 (新建默认: 127.0.0.1；已有配置未传 --in-proto 时原地修改 --in-index 指定入站)
      --port <port>         入站监听端口 (新建默认: 10808；已有配置未传 --in-proto 时原地修改 --in-index 指定入站)
      --tls-cert <path>     设置入站 TLS 证书文件路径 (certificateFile)
      --tls-key <path>      设置入站 TLS 私钥文件路径 (keyFile)
      --in-index <num>      指定操作的入站序号，用于 TLS 或原地修改监听/端口 (从 1 开始，默认: 1)
      --out-index <num>     将指定序号的出站切换为默认主出站 (从 1 开始，置顶到第 1 条)
      --direct              快捷模式将主出站切换为直连（已有 direct 出站时优先置顶，避免重复 tag）
      --link <uri>          快捷模式从分享链接解析主出站（单独传入时仅修改出站）
      --fresh               忽略现有 config.json，强制生成全新配置
      --install-xray        下载并执行官方 install-release.sh 安装/更新 Xray 后退出
      --xray-user <user>    配合 --install-xray 指定服务运行用户 (如 root，对应官方 -u 参数)
      --uninstall-xray      通过官方 install-release.sh 卸载 Xray 后退出
      --status              监测并展示 Xray 版本、服务状态、监听端口与最近日志后退出
      --start               启动 xray.service 服务后退出
      --stop                停止 xray.service 服务后退出
      --restart             重启 xray.service 服务后退出
  -u, --update              检查并更新当前脚本到最新版本后退出
      --update-url <url>    指定更新脚本的下载地址 (也可通过环境变量 XRAY_GEN_UPDATE_URL 指定)
  -h, --help                显示帮助信息
EOF
}

require_arg() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "错误：参数 $1 缺少值。" >&2
    exit 1
  fi
}

main() {
  local config_file="./config.json"
  local show_only="false"
  local fresh_mode="false"
  local do_update="false"
  local update_url=""
  local do_install_xray="false"
  local do_uninstall_xray="false"
  local xray_user=""
  local do_status="false"
  local service_action=""
  local in_proto=""
  local listen="127.0.0.1"
  local port="10808"
  local tls_cert=""
  local tls_key=""
  local in_index="1"
  local out_index=""
  local use_direct="false"
  local link=""
  local has_in_proto="false"
  local has_listen_arg="false"
  local has_port_arg="false"
  local has_tls_args="false"
  local has_out_args="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|-o|--output)  require_arg "$1" "${2:-}"; config_file="$2"; shift 2 ;;
      -s|--show)       show_only="true"; shift ;;
      --fresh)         fresh_mode="true"; shift ;;
      -u|--update)     do_update="true"; shift ;;
      --update-url)    require_arg "$1" "${2:-}"; update_url="$2"; shift 2 ;;
      --install-xray)  do_install_xray="true"; shift ;;
      --xray-user)     require_arg "$1" "${2:-}"; xray_user="$2"; shift 2 ;;
      --uninstall-xray) do_uninstall_xray="true"; shift ;;
      --status)        do_status="true"; shift ;;
      --start)         service_action="start"; shift ;;
      --stop)          service_action="stop"; shift ;;
      --restart)       service_action="restart"; shift ;;
      --in-proto)      require_arg "$1" "${2:-}"; in_proto="$2"; has_in_proto="true"; shift 2 ;;
      --listen)        require_arg "$1" "${2:-}"; listen="$2"; has_listen_arg="true"; shift 2 ;;
      --port)          require_arg "$1" "${2:-}"; port="$2"; has_port_arg="true"; shift 2 ;;
      --tls-cert)      require_arg "$1" "${2:-}"; tls_cert="$2"; has_tls_args="true"; shift 2 ;;
      --tls-key)       require_arg "$1" "${2:-}"; tls_key="$2"; has_tls_args="true"; shift 2 ;;
      --in-index)      require_arg "$1" "${2:-}"; in_index="$2"; shift 2 ;;
      --out-index)     require_arg "$1" "${2:-}"; out_index="$2"; shift 2 ;;
      --direct)        use_direct="true"; has_out_args="true"; shift ;;
      --link)          require_arg "$1" "${2:-}"; link="$2"; has_out_args="true"; shift 2 ;;
      -h|--help)       usage; exit 0 ;;
      *)
        echo "未知参数: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  if [[ "$do_update" == "true" ]]; then
    self_update "$update_url"
    exit 0
  fi

  if [[ "$do_install_xray" == "true" ]]; then
    if [[ -n "$xray_user" ]]; then
      install_xray install -u "$xray_user"
    else
      install_xray install
    fi
    exit 0
  fi

  if [[ "$do_uninstall_xray" == "true" ]]; then
    install_xray remove
    exit 0
  fi

  if [[ -n "$service_action" ]]; then
    control_xray_service "$service_action"
    exit 0
  fi

  if [[ "$do_status" == "true" ]]; then
    show_xray_status "$config_file"
    exit 0
  fi

  local is_quick_mode="false"
  if [[ "$has_in_proto" == "true" || "$has_listen_arg" == "true" || "$has_port_arg" == "true" || "$has_tls_args" == "true" || "$has_out_args" == "true" || -n "$out_index" ]]; then
    is_quick_mode="true"
  fi

  if [[ "$show_only" == "true" || "$is_quick_mode" == "true" || ( "$fresh_mode" == "false" && -f "$config_file" ) ]]; then
    check_deps
  fi

  if [[ "$has_port_arg" == "true" ]] && ! is_valid_port "$port"; then
    echo "错误：--port 端口号无效: ${port}（有效范围 1-65535，不含前导零）。" >&2
    exit 1
  fi

  local has_existing="false"
  if [[ "$fresh_mode" == "false" && -f "$config_file" ]]; then
    local load_rc=0
    load_existing_config "$config_file" || load_rc=$?
    if (( load_rc == 0 )); then
      has_existing="true"
    elif (( load_rc == 2 )); then
      echo "错误：${config_file} 已存在但不是合法的 JSON 对象（可能含注释的 JSONC 或格式损坏）。" >&2
      echo "请先修复/移除注释，或使用 --fresh 强制重新生成（会覆盖原文件）。" >&2
      exit 1
    fi
  fi

  # 仅查看模式
  if [[ "$show_only" == "true" ]]; then
    if [[ "$has_existing" == "false" ]]; then
      echo "错误：未找到配置文件 ${config_file}" >&2
      exit 1
    fi
    show_config_summary "$config_file"
    exit 0
  fi

  # 命令行快捷模式（支持只改入站、只改监听/端口、只改 TLS 路径或只改出站）
  if [[ "$is_quick_mode" == "true" ]]; then
    if [[ -n "$out_index" && "$has_out_args" == "true" ]]; then
      echo "错误：--out-index 不能与 --direct 或 --link 同时使用。" >&2
      exit 1
    fi
    if [[ -n "$out_index" && "$has_existing" == "false" ]]; then
      echo "错误：未找到有效的配置文件 ${config_file}，无法通过 --out-index 切换出站。" >&2
      exit 1
    fi

    if [[ "$has_in_proto" == "true" || "$has_existing" == "false" ]]; then
      in_proto="${in_proto:-socks}"
      in_proto="$(printf '%s' "$in_proto" | tr '[:upper:]' '[:lower:]')"
      if [[ "$in_proto" == "socks" ]]; then
        INBOUNDS_JSON="$(jq -n --arg listen "$listen" --argjson port "$port" '
          [{
            tag: "socks-in",
            listen: $listen,
            port: $port,
            protocol: "socks",
            settings: { auth: "noauth", udp: true },
            sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
          }]
        ')"
      elif [[ "$in_proto" == "http" ]]; then
        INBOUNDS_JSON="$(jq -n --arg listen "$listen" --argjson port "$port" '
          [{
            tag: "http-in",
            listen: $listen,
            port: $port,
            protocol: "http",
            settings: {},
            sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
          }]
        ')"
      else
        echo "错误：快捷模式 --in-proto 仅支持 socks 或 http。" >&2
        exit 1
      fi
    elif [[ "$has_listen_arg" == "true" || "$has_port_arg" == "true" ]]; then
      update_inbound_endpoint "$in_index" "$has_listen_arg" "$listen" "$has_port_arg" "$port"
    fi

    if [[ "$has_tls_args" == "true" ]]; then
      apply_tls_to_inbound "$in_index" "$tls_cert" "$tls_key"
    fi

    if [[ -n "$out_index" ]]; then
      set_primary_outbound "$out_index"
    elif [[ "$has_out_args" == "true" || "$has_existing" == "false" ]]; then
      if [[ -n "$link" ]]; then
        local proxy_out
        proxy_out="$(parse_share_link "$link" "proxy")"
        if [[ "$has_existing" == "true" && "$(printf '%s' "$OUTBOUNDS_JSON" | jq 'length')" -gt 0 ]]; then
          OUTBOUNDS_JSON="$(printf '%s' "$OUTBOUNDS_JSON" | jq --argjson p "$proxy_out" '.[0] = $p')"
        else
          OUTBOUNDS_JSON="$(jq -n --argjson p "$proxy_out" '
            [
              $p,
              { tag: "direct", protocol: "freedom" },
              { tag: "block", protocol: "blackhole" }
            ]
          ')"
        fi
      else
        local direct_idx
        direct_idx="$(printf '%s' "$OUTBOUNDS_JSON" | jq '([to_entries[] | select(.value.protocol == "freedom" and .value.tag == "direct") | .key + 1][0]) // 0')"
        if [[ "$has_existing" == "true" && "$direct_idx" -gt 0 ]]; then
          set_primary_outbound "$direct_idx"
        elif [[ "$has_existing" == "true" && "$(printf '%s' "$OUTBOUNDS_JSON" | jq 'length')" -gt 0 ]]; then
          local direct_out='{"tag":"direct","protocol":"freedom"}'
          OUTBOUNDS_JSON="$(printf '%s' "$OUTBOUNDS_JSON" | jq --argjson d "$direct_out" '.[0] = $d')"
        else
          OUTBOUNDS_JSON='[
            { "tag": "direct", "protocol": "freedom" },
            { "tag": "block", "protocol": "blackhole" }
          ]'
        fi
      fi
    fi

    save_config "$config_file" "false"
    show_config_summary "$config_file"
    exit 0
  fi

  # 交互式模式
  if [[ "$has_existing" == "true" ]]; then
    local orig_inbounds="$INBOUNDS_JSON"
    local orig_outbounds="$OUTBOUNDS_JSON"
    show_config_summary "$config_file"
    echo "" >&2
    ui_section "主菜单" "请选择要执行的操作"
    ui_item "1" "只修改入站" "覆盖 / 追加 / 删除 / TLS 路径"
    ui_item "2" "只修改出站" "替换 / 重置 / 追加 / 删除 / 切换主出站"
    ui_item "3" "设置入站 TLS 证书路径" "快捷修改 certificateFile 与 keyFile" "$C_GREEN"
    ui_item "4" "同时修改入站和出站" "保留 log / routing / dns 等其他字段"
    ui_item "5" "全新生成配置" "忽略原文件内容，重新引导生成" "$C_YELLOW"
    ui_hr
    ui_item "6" "Xray 状态监测与服务管理" "查看版本 / 状态 / 端口 / 日志 / 启停重启" "$C_CYAN"
    ui_item "7" "安装 / 更新 / 卸载 Xray" "执行官方 install-release.sh" "$C_GREEN"
    ui_item "8" "更新本脚本" "检查并更新 xray_gen.sh 到最新版本" "$C_GREEN"
    ui_item "0" "退出" "不修改配置直接退出" "$C_DIM"
    echo "" >&2

    local action
    action="$(ask "请选择 (0-8)" "3")"
    case "$action" in
      1)
        edit_existing_inbounds_interactive
        ;;
      2)
        edit_existing_outbounds_interactive
        ;;
      3)
        configure_tls_cert_paths_interactive
        ;;
      4)
        edit_existing_inbounds_interactive
        edit_existing_outbounds_interactive
        ;;
      5)
        BASE_CONFIG_JSON=""
        INBOUNDS_JSON="$(build_inbounds_interactive)"
        configure_full_outbounds_interactive
        ;;
      6)
        monitor_xray_interactive "$config_file"
        exit 0
        ;;
      7)
        manage_xray_install_interactive
        exit 0
        ;;
      8)
        local target_url="${update_url:-${XRAY_GEN_UPDATE_URL:-$DEFAULT_UPDATE_URL}}"
        target_url="$(ask "更新脚本 URL (回车使用默认地址)" "$target_url")"
        self_update "$target_url"
        exit 0
        ;;
      0)
        echo "已退出，未修改配置。"
        exit 0
        ;;
      *)
        echo "无效选项。" >&2
        exit 1
        ;;
    esac
    if [[ "$action" != "5" && "$INBOUNDS_JSON" == "$orig_inbounds" && "$OUTBOUNDS_JSON" == "$orig_outbounds" ]]; then
      echo "配置未发生变化，已退出。"
      exit 0
    fi
    config_file="$(ask "保存配置文件路径" "$config_file")"
  else
    echo "" >&2
    ui_hr
    printf '  %s%s◆ Xray 配置与管理工具%s  %s(未检测到 %s)%s\n' "$C_BOLD" "$C_CYAN" "$C_RESET" "$C_DIM" "$config_file" "$C_RESET" >&2
    printf '  %s● Xray 状态:%s %s\n' "$C_DIM" "$C_RESET" "$(get_xray_brief_status)" >&2
    ui_hr
    echo "" >&2
    ui_section "主菜单" "请选择要执行的操作"
    ui_item "1" "生成新配置" "引导创建 ${config_file}" "$C_GREEN"
    ui_item "2" "Xray 状态监测与服务管理" "查看版本 / 状态 / 端口 / 日志 / 启停重启" "$C_CYAN"
    ui_item "3" "安装 / 更新 / 卸载 Xray" "执行官方 install-release.sh" "$C_GREEN"
    ui_item "4" "更新本脚本" "检查并更新 xray_gen.sh 到最新版本" "$C_GREEN"
    ui_item "0" "退出" "" "$C_DIM"
    echo "" >&2

    local action
    action="$(ask "请选择 (0-4)" "1")"
    case "$action" in
      1)
        check_deps
        INBOUNDS_JSON="$(build_inbounds_interactive)"
        configure_full_outbounds_interactive
        config_file="$(ask "输出文件路径" "$config_file")"
        ;;
      2)
        monitor_xray_interactive "$config_file"
        exit 0
        ;;
      3)
        manage_xray_install_interactive
        exit 0
        ;;
      4)
        local target_url="${update_url:-${XRAY_GEN_UPDATE_URL:-$DEFAULT_UPDATE_URL}}"
        target_url="$(ask "更新脚本 URL (回车使用默认地址)" "$target_url")"
        self_update "$target_url"
        exit 0
        ;;
      0)
        echo "已退出。"
        exit 0
        ;;
      *)
        echo "无效选项。" >&2
        exit 1
        ;;
    esac
  fi

  save_config "$config_file" "true"
  show_config_summary "$config_file"
}

main "$@"
