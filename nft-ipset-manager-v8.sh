#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail
umask 077
TEMP_PATHS=()
cleanup_temp_paths(){ local p; for p in "${TEMP_PATHS[@]}"; do [[ -n "$p" ]] && rm -rf -- "$p"; done; }
trap cleanup_temp_paths EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
register_temp(){ TEMP_PATHS+=("$1"); }
atomic_copy(){
  local src="$1" dst="$2" dir tmp cur
  dir=$(dirname "$dst")
  cur="$dir"
  while [[ "$cur" != "/" ]]; do
    [[ ! -L "$cur" ]] || { echo -e "${RED}拒绝写入包含符号链接的路径：$dst${NC}" >&2; return 1; }
    cur=$(dirname "$cur")
  done
  [[ ! -L "$dst" ]] || { echo -e "${RED}拒绝写入符号链接路径：$dst${NC}" >&2; return 1; }
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.atomic.XXXXXX") || return 1
  register_temp "$tmp"
  cat "$src" > "$tmp" || return 1
  chmod 0600 "$tmp"
  mv -f "$tmp" "$dst"
}
check_data_dirs(){
  local d
  for d in "$BASE_DIR" "$WL_DIR" "$BD_DIR" "$GROUP_DIR" "$NFT_DIR"; do
    [[ ! -L "$d" ]] || { echo -e "${RED}拒绝使用符号链接目录：$d${NC}" >&2; return 1; }
  done
}
check_data_files(){
  local f
  for f in "$GROUP_DB" "$CONFIG_FILE" "$USAGE_FILE" "$RULESET_FILE"; do
    [[ ! -L "$f" ]] || { echo -e "${RED}拒绝使用符号链接文件：$f${NC}" >&2; return 1; }
  done
}

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
BASE_DIR="$SCRIPT_DIR"
WL_DIR="$BASE_DIR/wl"
BD_DIR="$BASE_DIR/bd"
GROUP_DIR="$BASE_DIR/groups"
NFT_DIR="$BASE_DIR/nft"
GROUP_DB="$BASE_DIR/groups.tsv"
CONFIG_FILE="$BASE_DIR/config.conf"
USAGE_FILE="$BASE_DIR/使用说明.md"
RULESET_FILE="$NFT_DIR/ruleset.nft"
DEFAULT_PORT="22"
FIREWALL_MODE="global"
MENU_SHORTCUT=""
TABLE_NAME="ipmgr"
CHAIN_NAME="input"
SERVICE_NAME="ipmgr-nft.service"
PERSISTENCE_FILE="/etc/nftables.d/ipmgr.nft"
UNIT_FILE="/etc/systemd/system/$SERVICE_NAME"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

need_root(){ [[ ${EUID} -eq 0 ]] || { echo -e "${RED}请用 root 运行：sudo bash $0${NC}"; exit 1; }; }
ensure_dirs(){ mkdir -p "$WL_DIR" "$BD_DIR" "$GROUP_DIR" "$NFT_DIR"; }

ensure_usage_doc(){
  [[ -f "$USAGE_FILE" ]] && return
  cat > "$USAGE_FILE" <<'EOF'
# nftables set IP 白名单管理脚本说明

适用：Debian 11 / Debian 12 / Debian 13，大量 IP/CIDR 白名单场景，也兼顾少量 IP 添加删除。

## 目录结构
脚本放在哪个目录，数据就保存在哪个目录：
- wl/：URL 下载缓存
- bd/：本地导入缓存
- groups/：每个分组的 IP/CIDR 列表
- nft/ruleset.nft：生成的 nftables 规则文件
- groups.tsv：分组元数据
- config.conf：默认端口配置

## 核心逻辑
- 每个分组单独保存。
- 应用规则时自动去重、合并 CIDR。
- 使用 nftables interval set，适合大量 IP 库。
- 规则一次性生成并 nft -f 原子加载。
- 添加/删除 IP 或分组后会自动生成并应用规则；菜单 10 用于手动重新应用，菜单 16 用于带确认的初始化应用。
- 支持“全局白名单”和“仅限制已配置端口”两种管理范围；后者适合只保护例如 8888/tcp 的服务。
- 菜单 12/13/14 可启动、停止、重启白名单服务，标题会显示服务状态。

## 建议
- 大量 IP 库用 URL/本地批量导入。
- 少量 IP 用“手动添加单个 IP/CIDR”。
- 当前管理 IP 可用“自动获取当前 IPv4 并加入白名单”，会单独保存到 AUTO_CURRENT_IP 分组。
- 删除建议按分组删除；单条误加可用“从分组删除单个 IP/CIDR”。
- 如果要接管入站防火墙，先确认当前 SSH IP 已放行。

## 持久化与快捷命令
菜单 15 可启用或关闭开机持久化；关闭时停止并禁用独立服务，但保留服务文件和规则文件。
菜单 19 可设置或移除脚本菜单快捷命令，例如 `nf`。快捷命令安装在 `/usr/local/bin`，执行后打开本脚本菜单。

端口模式仅使用绑定了具体 TCP/UDP 端口的分组；全端口分组会显示为未加载。

## 依赖与升级
必要组件：nftables、curl、python3、ca-certificates。菜单 19 可检查、安装或从当前 Debian 官方仓库更新这些组件。脚本不会添加 testing、backports 或第三方软件源，避免破坏 Debian 11/12/13 的依赖关系。
EOF
}

load_config(){
  [[ -f "$CONFIG_FILE" ]] || return 0
  local p
  p=$(grep -E '^DEFAULT_PORT="?[0-9]{1,5}"?$' "$CONFIG_FILE" 2>/dev/null | tail -n1 | sed -E 's/^DEFAULT_PORT="?([0-9]{1,5})"?$/\1/' || true)
  [[ -n "${p:-}" ]] && (( p>=1 && p<=65535 )) && DEFAULT_PORT="$p"
  p=$(grep -E '^FIREWALL_MODE="?(global|port_only)"?$' "$CONFIG_FILE" 2>/dev/null | tail -n1 | sed -E 's/^FIREWALL_MODE="?(global|port_only)"?$/\1/' || true)
  [[ -n "${p:-}" ]] && FIREWALL_MODE="$p"
  MENU_SHORTCUT=$(grep -E '^MENU_SHORTCUT="?[A-Za-z0-9_-]*"?$' "$CONFIG_FILE" 2>/dev/null | tail -n1 | sed -E 's/^MENU_SHORTCUT="?([A-Za-z0-9_-]*)"?$/\1/' || true)
}
save_config(){
  local tmp
  [[ ! -L "$CONFIG_FILE" ]] || { echo -e "${RED}配置文件是符号链接，拒绝覆盖。${NC}" >&2; return 1; }
  tmp=$(mktemp "$BASE_DIR/.config.XXXXXX") || return 1
  register_temp "$tmp"
  printf 'DEFAULT_PORT="%s"\nFIREWALL_MODE="%s"\nMENU_SHORTCUT="%s"\n' "$DEFAULT_PORT" "$FIREWALL_MODE" "$MENU_SHORTCUT" > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$CONFIG_FILE"
}
install_deps(){ local n=""; command -v nft >/dev/null 2>&1 || n="$n nftables"; command -v curl >/dev/null 2>&1 || n="$n curl"; command -v python3 >/dev/null 2>&1 || n="$n python3"; [[ -f /etc/ssl/certs/ca-certificates.crt ]] || n="$n ca-certificates"; [[ -n "$n" ]] && { apt update; apt install -y $n; }; return 0; }

manage_dependencies(){
  local choice missing=""
  echo -e "${BLUE}系统信息：${NC}"
  if [[ -r /etc/os-release ]]; then
    grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release | sed 's/^/  /'
  fi
  echo -e "${BLUE}组件状态：${NC}"
  if command -v nft >/dev/null 2>&1; then echo "  nftables: $(nft --version 2>/dev/null || echo 已安装)"; else echo "  nftables: 缺失"; missing="$missing nftables"; fi
  if command -v curl >/dev/null 2>&1; then echo "  curl: $(curl --version 2>/dev/null | head -n1)"; else echo "  curl: 缺失"; missing="$missing curl"; fi
  if command -v python3 >/dev/null 2>&1; then echo "  python3: $(python3 --version 2>&1)"; else echo "  python3: 缺失"; missing="$missing python3"; fi
  if [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then echo "  ca-certificates: 已安装"; else echo "  ca-certificates: 缺失"; missing="$missing ca-certificates"; fi
  if command -v systemctl >/dev/null 2>&1; then
    echo "  nftables 服务启用状态: $(systemctl is-enabled nftables 2>/dev/null || echo 未启用)"
    echo "  nftables 服务运行状态: $(systemctl is-active nftables 2>/dev/null || echo 未运行)"
  fi

  echo "请选择："
  echo "1) 只检查，不安装"
  echo "2) 安装缺失依赖"
  echo "3) 从当前 Debian 官方仓库更新必要组件"
  read -rp "选择 [1-3]：" choice
  case "$choice" in
    1) return 0 ;;
    2)
      if [[ -z "$missing" ]]; then echo -e "${GREEN}必要依赖已齐全。${NC}"; return 0; fi
      apt update && apt install -y $missing
      ;;
    3)
      echo -e "${YELLOW}只使用当前系统已配置的软件源，不添加 testing/backports 或第三方源。${NC}"
      apt update && apt install -y --only-upgrade nftables curl python3 ca-certificates
      ;;
    *) echo -e "${RED}无效选择。${NC}"; return 1 ;;
  esac
  echo -e "${GREEN}依赖操作完成。${NC}"
}
pause(){ read -rp "按回车继续..." _; }

is_valid_group(){ [[ "$1" =~ ^[A-Za-z0-9._-]{1,32}$ && "$1" != . && "$1" != .. ]]; }
is_valid_port(){ [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1>=1 && 10#$1<=65535)); }
is_valid_proto(){ [[ "$1" == tcp || "$1" == udp ]]; }
is_valid_url(){ [[ "$1" =~ ^https?://[^[:space:]]+$ ]]; }
normalize_ip(){ python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' "$1"; }
is_valid_ip(){ python3 -c 'import ipaddress,sys; n=ipaddress.ip_network(sys.argv[1], strict=False); sys.exit(1 if n.prefixlen == 0 else 0)' "$1" >/dev/null 2>&1; }
ask_group(){ local g; read -rp "$1" g; is_valid_group "$g" || { echo -e "${RED}名称不合法。${NC}" >&2; return 1; }; echo "$g"; }
ask_port(){ local p; read -rp "$1" p; is_valid_port "$p" || { echo -e "${RED}端口不正确。${NC}" >&2; return 1; }; echo "$p"; }
ask_proto(){ local p; read -rp "协议 tcp/udp，默认 tcp：" p; p=${p:-tcp}; is_valid_proto "$p" || { echo -e "${RED}协议不正确。${NC}" >&2; return 1; }; echo "$p"; }
ask_ip(){ local ip; read -rp "$1" ip; is_valid_ip "$ip" || { echo -e "${RED}IP/CIDR 不正确。${NC}" >&2; return 1; }; normalize_ip "$ip"; }

group_file(){
  local g="$1" f
  is_valid_group "$g" || return 1
  f="$GROUP_DIR/$g.list"
  [[ ! -L "$f" ]] || { echo -e "${RED}分组文件是符号链接，拒绝操作：$f${NC}" >&2; return 1; }
  printf '%s\n' "$f"
}
timestamp_name(){ printf '%s_%s' "$(date +%Y%m%d_%H%M%S)" "$1"; }
cache_wl_path(){ mktemp "$WL_DIR/.wl-cache.XXXXXX"; }
cache_bd_path(){ mktemp "$BD_DIR/.bd-cache.XXXXXX"; }

is_valid_shortcut(){ [[ "$1" =~ ^[A-Za-z][A-Za-z0-9_-]{0,31}$ ]]; }
meta_record_valid(){
  local group="$1" source="$2" mode="$3" port="$4" proto="$5" cache="$6" ts="$7"
  is_valid_group "$group" || return 1
  [[ "$source" != *$'\t'* && "$source" != *$'\n'* && "$cache" != *$'\t'* && "$cache" != *$'\n'* ]] || return 1
  [[ "$ts" =~ ^[0-9]+$ ]] || return 1
  case "$mode" in
    all) [[ "$port" == 0 && "$proto" == any ]] || return 1;;
    port) is_valid_port "$port" && is_valid_proto "$proto" || return 1;;
    *) return 1;;
  esac
}

choose_mode(){
  local m p port
  if [[ "$FIREWALL_MODE" == port_only ]]; then
    echo "当前为仅限制已配置端口模式，只为此 IP/CIDR 指定要保护的端口。" >&2
    port=$(ask_port "请输入要限制的端口：")||return 1
    p=$(ask_proto)||return 1
    echo "port|$port|$p"
    return 0
  fi
  echo "请选择放行方式：" >&2
  echo "1) 允许访问所有端口" >&2
  echo "2) 仅允许访问默认端口 ${DEFAULT_PORT}" >&2
  echo "3) 仅允许访问指定端口" >&2
  read -rp "选择 [1-3]：" m
  case "$m" in
    1) echo "all|0|any";;
    2) p=$(ask_proto)||return 1; echo "port|$DEFAULT_PORT|$p";;
    3) port=$(ask_port "请输入端口：")||return 1; p=$(ask_proto)||return 1; echo "port|$port|$p";;
    *) echo -e "${RED}无效选择。${NC}" >&2; return 1;;
  esac
}

parse_file(){
  python3 - "$1" <<'PY'
import ipaddress, sys, re
seen=set()
try:
    stream=open(sys.argv[1], encoding='utf-8', errors='replace')
except (OSError, ValueError) as e:
    print(f'无法读取导入文件：{e}', file=sys.stderr)
    sys.exit(1)
with stream:
    for raw in stream:
        line=raw.strip()
        if not line or line.startswith('#'): continue
        line=re.split(r'[\s,#]+', line, 1)[0].strip()
        if not line: continue
        try:
            network=ipaddress.ip_network(line, strict=False)
            if network.prefixlen == 0: continue
            net=str(network)
        except ValueError: continue
        if net not in seen:
            seen.add(net); print(net)
PY
}
collapse_file(){
  python3 - "$1" <<'PY'
import ipaddress, sys
nets=[]
try:
    stream=open(sys.argv[1], encoding='utf-8', errors='replace')
except (OSError, ValueError) as e:
    print(f'无法读取文件：{e}', file=sys.stderr)
    sys.exit(1)
with stream:
    for line in stream:
        s=line.strip()
        if not s: continue
        try: nets.append(ipaddress.ip_network(s, strict=False))
        except ValueError: pass
v4=[n for n in nets if n.version==4]
v6=[n for n in nets if n.version==6]
for n in ipaddress.collapse_addresses(v4):
    if n.prefixlen: print(n)
for n in ipaddress.collapse_addresses(v6):
    if n.prefixlen: print(n)
PY
}
preview_list(){ local f="$1" n; n=$(wc -l < "$f" | tr -d ' '); echo -e "${BLUE}有效 IP/CIDR：$n 条${NC}"; echo -e "${YELLOW}预览前 20 条：${NC}"; nl -ba "$f" | sed -n '1,20p'; }

write_group_meta(){
  local group="$1" source="$2" mode="$3" port="$4" proto="$5" cache="$6" tmp
  is_valid_group "$group" || return 1
  source=${source//$'\t'/ }; source=${source//$'\n'/ }; source=${source//$'\r'/ }
  cache=${cache//$'\t'/ }; cache=${cache//$'\n'/ }; cache=${cache//$'\r'/ }
  touch "$GROUP_DB"
  tmp=$(mktemp "$BASE_DIR/.groups.XXXXXX") || return 1
  register_temp "$tmp"
  if ! awk -F '\t' -v g="$group" '$1!=g' "$GROUP_DB" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$group" "$source" "$mode" "$port" "$proto" "$cache" "$(date +%s)" >> "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 0600 "$tmp"
  mv "$tmp" "$GROUP_DB"
}
get_meta(){
  local record group source mode port proto cache ts
  record=$(awk -F '\t' -v g="$1" '$1==g{print; exit}' "$GROUP_DB" 2>/dev/null || true)
  [[ -n "$record" ]] || return 1
  IFS=$'\t' read -r group source mode port proto cache ts <<< "$record"
  meta_record_valid "$group" "$source" "$mode" "$port" "$proto" "$cache" "$ts" || return 1
  printf '%s\n' "$record"
}
list_groups(){
  [[ -s "$GROUP_DB" ]] || return 0
  while IFS=$'\t' read -r g source mode port proto cache ts; do
    meta_record_valid "$g" "$source" "$mode" "$port" "$proto" "$cache" "$ts" || continue
    printf '%s\n' "$g"
  done < "$GROUP_DB"
}
ensure_group_compatible(){
  local group="$1" meta source mode port proto cache ts modeinfo rest
  [[ "$FIREWALL_MODE" == port_only ]] || return 0
  meta=$(get_meta "$group") || { echo -e "${RED}分组 $group 的元数据无效，请检查 groups.tsv。${NC}"; return 1; }
  IFS=$'\t' read -r _ source mode port proto cache ts <<< "$meta"
  [[ "$mode" == all ]] || return 0
  echo -e "${YELLOW}分组 $group 原为全端口放行，端口限制模式不会加载全端口组。${NC}"
  modeinfo=$(choose_mode) || return 1
  mode=${modeinfo%%|*}; rest=${modeinfo#*|}; port=${rest%%|*}; proto=${rest#*|}
  write_group_meta "$group" "$source" "$mode" "$port" "$proto" "$cache"
  echo -e "${GREEN}分组 $group 已改为 ${proto}/${port} 端口规则。${NC}"
}
managed_unit(){
  [[ -f "$UNIT_FILE" && ! -L "$UNIT_FILE" ]] || return 1
  if [[ "$(sed -n '2p' "$UNIT_FILE" 2>/dev/null)" != '# Generated by nft-ipset-manager' ]]; then
    grep -Fxq 'Description=IP Manager nftables whitelist' "$UNIT_FILE" || return 1
  fi
  grep -Eq '^ExecStartPre=-.*/nft delete table inet ipmgr$' "$UNIT_FILE" || return 1
  grep -Eq '^ExecStart=.*/nft -f /etc/nftables.d/ipmgr\.nft$' "$UNIT_FILE" || return 1
  grep -Eq '^ExecStop=-.*/nft delete table inet ipmgr$' "$UNIT_FILE" || return 1
}
service_state(){
  if managed_unit; then
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && echo "运行中" || echo "已停止"
  elif nft list table inet "$TABLE_NAME" >/dev/null 2>&1; then
    echo "运行中"
  else
    echo "已停止"
  fi
}
persistence_state(){
  if managed_unit && systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "已启用"
  else
    echo "已停止"
  fi
}
show_service_state(){
  printf '白名单服务状态：%s\n' "$(service_state)"
  printf '开机持久化：%s\n' "$(persistence_state)"
  printf '脚本快捷键：%s\n' "${MENU_SHORTCUT:-未启用}"
}

show_groups(){
  [[ -s "$GROUP_DB" ]] || { echo -e "${YELLOW}暂无分组。${NC}"; return; }
  local i=0 g source mode port proto cache ts count scope
  while IFS=$'\t' read -r g source mode port proto cache ts; do
    meta_record_valid "$g" "$source" "$mode" "$port" "$proto" "$cache" "$ts" || continue
    i=$((i+1)); count=$(wc -l < "$(group_file "$g")" 2>/dev/null | tr -d ' ' || echo 0)
    scope=""
    [[ "$FIREWALL_MODE" == port_only && "$mode" == all ]] && scope=" | 当前端口模式不加载"
    printf '%d) 名称: %s | 数量: %s | 模式: %s' "$i" "$g" "$count" "$mode"
    [[ "$mode" != all ]] && printf ' | %s/%s' "$proto" "$port"
    printf ' | 来源: %s%s\n' "$source" "$scope"
  done < "$GROUP_DB"
}

resolve_group_by_input(){
  local sel="$1"
  if [[ "$sel" =~ ^[0-9]+$ ]]; then awk -F '\t' -v idx="$sel" 'NR==idx{print $1; exit}' "$GROUP_DB" 2>/dev/null; else echo "$sel"; fi
}

validate_download_url(){
  python3 - "$1" <<'PY'
import ipaddress, socket, sys
from urllib.parse import urlsplit
try:
    u = urlsplit(sys.argv[1])
    if u.scheme not in ('http', 'https') or not u.hostname or u.username or u.password:
        raise ValueError('仅接受不含凭据的 HTTP/HTTPS URL')
    port = u.port or (443 if u.scheme == 'https' else 80)
    if not 1 <= port <= 65535:
        raise ValueError('端口无效')
    try:
        addresses = {ipaddress.ip_address(u.hostname)}
    except ValueError:
        addresses = {ipaddress.ip_address(x[4][0]) for x in socket.getaddrinfo(u.hostname, port, type=socket.SOCK_STREAM)}
    if not addresses or any(not a.is_global for a in addresses):
        raise ValueError('URL 解析到非公网地址，已拒绝以避免访问内网服务')
    print(f'{u.hostname}|{port}|{sorted(addresses, key=lambda a: (a.version, int(a)))[0]}')
except Exception as e:
    print(f'URL 检查失败：{e}', file=sys.stderr)
    sys.exit(1)
PY
}

download_to_cache(){
  local url="$1" final="$2" tmp validated resolve_host port pin resolve_arg
  [[ ! -L "$final" ]] || { echo -e "${RED}缓存目标是符号链接，拒绝写入。${NC}"; return 1; }
  validated=$(validate_download_url "$url") || { rm -f -- "$final"; return 1; }
  IFS='|' read -r resolve_host port pin <<< "$validated"
  [[ "$resolve_host" == *:* ]] && resolve_host="[$resolve_host]"
  [[ "$pin" == *:* ]] && pin="[$pin]"
  resolve_arg="${resolve_host}:${port}:${pin}"
  tmp="$final.part"
  [[ ! -L "$final" && ! -L "$tmp" ]] || { echo -e "${RED}缓存目标是符号链接，拒绝写入。${NC}"; return 1; }
  rm -f -- "$tmp"
  register_temp "$tmp"
  echo -e "${BLUE}下载目标：$final（最大 100 MiB，固定公网解析地址，不跟随重定向）${NC}"
  (ulimit -f 204800; exec curl --disable --fail --proto '=http,https' --max-filesize 104857600 --connect-timeout 10 --max-time 120 --retry 1 --retry-delay 1 --silent --show-error --noproxy '*' --resolve "$resolve_arg" "$url" -o "$tmp") || { echo -e "${RED}下载失败或超过大小限制，已返回菜单。${NC}"; rm -f -- "$tmp" "$final"; return 1; }
  [[ -s "$tmp" ]] || { echo -e "${RED}下载文件为空，已丢弃。${NC}"; rm -f -- "$tmp" "$final"; return 1; }
  chmod 0600 "$tmp"
  mv -f "$tmp" "$final"
}

import_cache_as_group(){
  local group="$1" source="$2" cache="$3" modeinfo mode rest port proto parsed collapsed confirm gf
  parsed=$(mktemp); collapsed=$(mktemp); register_temp "$parsed"; register_temp "$collapsed"
  parse_file "$cache" > "$parsed"
  [[ -s "$parsed" ]] || { echo -e "${RED}没有解析到有效 IP/CIDR。${NC}"; rm -f "$parsed" "$collapsed"; return; }
  collapse_file "$parsed" > "$collapsed"
  echo -e "${BLUE}CIDR 合并前：$(wc -l < "$parsed" | tr -d ' ') 条，合并后：$(wc -l < "$collapsed" | tr -d ' ') 条${NC}"
  preview_list "$collapsed"
  read -rp "确认导入这个分组？[y/N]：" confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { rm -f "$parsed" "$collapsed"; echo "已取消。"; return; }
  modeinfo=$(choose_mode) || { rm -f "$parsed" "$collapsed"; return; }
  mode=${modeinfo%%|*}; rest=${modeinfo#*|}; port=${rest%%|*}; proto=${rest#*|}
  gf=$(group_file "$group")
  local group_tmp
  group_tmp=$(mktemp "$GROUP_DIR/.${group}.import.XXXXXX"); register_temp "$group_tmp"
  cp "$collapsed" "$group_tmp"
  chmod 0600 "$group_tmp"
  write_group_meta "$group" "$source" "$mode" "$port" "$proto" "$cache" || return 1
  mv -f "$group_tmp" "$gf"
  rm -f "$parsed" "$collapsed"
  echo -e "${GREEN}分组 $group 已保存。${NC}"
  auto_apply_after_change
}

add_group_from_url(){ local group url cache; group=$(ask_group "请输入分组名称/编号：")||return; read -rp "请输入下载链接：" url; is_valid_url "$url" || { echo -e "${RED}URL 不合法。${NC}"; return; }; cache=$(cache_wl_path "$url"); download_to_cache "$url" "$cache" || return; import_cache_as_group "$group" "$url" "$cache"; }
resolve_file(){
  local s="$1" candidate name
  [[ -n "$s" && "$s" != /* && "$s" != *".."* && "$s" != */* && "$s" != *$'\n'* && "$s" != *$'\r'* ]] || {
    echo -e "${RED}只允许输入数据目录内的文件名，不允许路径。${NC}" >&2
    return 1
  }
  name=$(basename "$s")
  for candidate in "$BASE_DIR/$name" "$BD_DIR/$name" "$WL_DIR/$name"; do
    [[ -f "$candidate" ]] || continue
    [[ ! -L "$candidate" ]] || { echo -e "${RED}不允许通过符号链接导入文件。${NC}" >&2; return 1; }
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}
add_group_from_local(){ local group src file cache; group=$(ask_group "请输入分组名称/编号：")||return; read -rp "请输入本地 txt 文件名或路径：" src; file=$(resolve_file "$src") || { echo -e "${RED}找不到文件。${NC}"; return; }; cache=$(cache_bd_path "$file") || return 1; atomic_copy "$file" "$cache" || return 1; import_cache_as_group "$group" "$cache" "$cache"; }

add_single_ip(){
  local group ip modeinfo mode rest port proto gf tmp
  group=$(ask_group "请输入分组名称/编号：")||return
  ip=$(ask_ip "请输入 IP/CIDR：")||return
  if [[ -f "$(group_file "$group")" ]]; then
    local meta
    meta=$(get_meta "$group") || { echo -e "${RED}分组 $group 的元数据无效，请检查 groups.tsv。${NC}"; return 1; }
    IFS=$'\t' read -r _ _ mode port proto _ _ <<< "$meta"
    ensure_group_compatible "$group" || return
  else
    modeinfo=$(choose_mode)||return; mode=${modeinfo%%|*}; rest=${modeinfo#*|}; port=${rest%%|*}; proto=${rest#*|}
    write_group_meta "$group" "manual" "$mode" "$port" "$proto" "manual" || return
  fi
  gf=$(group_file "$group"); touch "$gf"
  if grep -Fxq "$ip" "$gf"; then
    echo -e "${YELLOW}$ip 已存在于 $group，不重复添加。${NC}"
    return
  fi
  tmp=$(mktemp "$GROUP_DIR/.${group}.XXXXXX"); register_temp "$tmp"
  local collapsed
  collapsed=$(mktemp "$GROUP_DIR/.${group}.collapsed.XXXXXX"); register_temp "$collapsed"
  cat "$gf" > "$tmp"
  printf '%s\n' "$ip" >> "$tmp"
  collapse_file "$tmp" > "$collapsed"
  mv "$collapsed" "$gf"
  rm -f "$tmp"
  echo -e "${GREEN}已加入分组 $group。${NC}"
  auto_apply_after_change
}

auto_add_current_ip(){
  local group="AUTO_CURRENT_IP" current use24 ip modeinfo mode rest port proto gf tmp
  current=""

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    current=${SSH_CONNECTION%% *}
  elif [[ -n "${SSH_CLIENT:-}" ]]; then
    current=${SSH_CLIENT%% *}
  fi

  if ! python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]).version == 4 else 1)' "${current:-}" >/dev/null 2>&1; then
    echo -e "${YELLOW}无法从当前环境识别 SSH 客户端公网 IPv4。${NC}"
    echo -e "${YELLOW}注意：在 VPS 上访问 ifconfig.me 得到的是 VPS 自己的公网 IP，不是你的客户端 IP。${NC}"
    read -rp "请手动输入当前 SSH 客户端 IPv4，输入 0 返回：" current
    [[ "$current" == "0" ]] && return
    if ! python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]).version == 4 else 1)' "$current" >/dev/null 2>&1; then
      echo -e "${RED}IPv4 地址无效。${NC}"
      return
    fi
  fi

  current=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_address(sys.argv[1]))' "$current")
  echo -e "${GREEN}当前 SSH 客户端 IPv4：$current${NC}"
  read -rp "是否按 /24 添加？[y/N]：" use24
  if [[ "$use24" =~ ^[Yy]$ ]]; then
    ip=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1] + "/24", strict=False))' "$current")
  else
    ip="$current/32"
  fi
  echo -e "${YELLOW}将加入专用分组 $group：$ip${NC}"

  if [[ -f "$(group_file "$group")" ]]; then
    local meta
    meta=$(get_meta "$group") || { echo -e "${RED}分组 $group 的元数据无效，请检查 groups.tsv。${NC}"; return 1; }
    IFS=$'\t' read -r _ _ mode port proto _ _ <<< "$meta"
    ensure_group_compatible "$group" || return
  else
    echo -e "${YELLOW}首次创建 $group 分组，请选择这个分组的放行方式。${NC}"
    modeinfo=$(choose_mode)||return
    mode=${modeinfo%%|*}; rest=${modeinfo#*|}; port=${rest%%|*}; proto=${rest#*|}
    write_group_meta "$group" "auto-ssh-client-ip" "$mode" "$port" "$proto" "auto"
  fi

  gf=$(group_file "$group"); touch "$gf"
  if grep -Fxq "$ip" "$gf"; then
    echo -e "${YELLOW}$ip 已存在于 $group，不重复添加。${NC}"
    return
  fi
  printf '%s\n' "$ip" >> "$gf"
  tmp=$(mktemp); collapse_file "$gf" > "$tmp"; mv "$tmp" "$gf"
  echo -e "${GREEN}已添加到 $group。${NC}"
  auto_apply_after_change
}

delete_single_ip(){
  local group ip gf tmp
  show_groups; group=$(ask_group "请输入分组名称：")||return; gf=$(group_file "$group"); [[ -f "$gf" ]] || { echo -e "${RED}分组不存在。${NC}"; return; }
  ip=$(ask_ip "请输入要从分组删除的 IP/CIDR：")||return
  if ! grep -Fxq "$ip" "$gf"; then
    echo -e "${YELLOW}$ip 不在分组 $group 中，无需删除。${NC}"
    return
  fi
  tmp=$(mktemp); awk -v x="$ip" '$0!=x' "$gf" > "$tmp"; mv "$tmp" "$gf"
  echo -e "${GREEN}已从分组文件删除精确匹配项。${NC}"
  auto_apply_after_change
}

delete_group(){
  local sel group confirm
  show_groups; read -rp "请输入要删除的分组名称或序号：" sel; group=$(resolve_group_by_input "$sel")
  [[ -n "$group" && -f "$(group_file "$group")" ]] || { echo -e "${RED}分组不存在。${NC}"; return; }
  read -rp "确认删除分组 $group？[y/N]：" confirm; [[ "$confirm" =~ ^[Yy]$ ]] || return
  rm -f "$(group_file "$group")"; awk -F '\t' -v g="$group" '$1!=g' "$GROUP_DB" > "$GROUP_DB.tmp" || true; mv "$GROUP_DB.tmp" "$GROUP_DB"
  echo -e "${GREEN}分组已删除。${NC}"
  auto_apply_after_change
}

sanitize_set(){ echo "$1" | tr '.-' '__' | tr -cd 'A-Za-z0-9_'; }
make_elements(){ python3 - "$1" "$2" <<'PY'
import sys, ipaddress
ver=int(sys.argv[2]); xs=[]
for line in open(sys.argv[1]):
    s=line.strip()
    if not s: continue
    try:
        n=ipaddress.ip_network(s, strict=False)
        if n.version==ver and n.prefixlen > 0: xs.append(n)
    except Exception: pass
xs=list(ipaddress.collapse_addresses(xs))
if xs:
    print(', '.join(str(x) for x in xs))
PY
}

generate_ruleset(){
  local out="$RULESET_FILE" tmpdir allfile g source mode port proto cache ts key f set4 set6 elems4 elems6 outtmp
  tmpdir=$(mktemp -d); register_temp "$tmpdir"; outtmp=$(mktemp "$NFT_DIR/.ruleset.XXXXXX"); register_temp "$outtmp"; : > "$tmpdir/allkeys"
  while IFS=$'\t' read -r g source mode port proto cache ts; do
    meta_record_valid "$g" "$source" "$mode" "$port" "$proto" "$cache" "$ts" || continue
    [[ -f "$(group_file "$g")" ]] || continue
    if [[ "$FIREWALL_MODE" == port_only && "$mode" == all ]]; then
      continue
    fi
    key="$mode|$port|$proto"; echo "$key" >> "$tmpdir/allkeys"; cat "$(group_file "$g")" >> "$tmpdir/$key" 2>/dev/null || true
  done < "$GROUP_DB" 2>/dev/null || true
  {
    echo 'table inet ipmgr {'
    sort -u "$tmpdir/allkeys" 2>/dev/null | while IFS='|' read -r mode port proto; do
      [[ -n "${mode:-}" ]] || continue
      f="$tmpdir/$mode|$port|$proto"; collapse_file "$f" > "$f.c"
      set4="allow4_$(sanitize_set "${mode}_${proto}_${port}")"; set6="allow6_$(sanitize_set "${mode}_${proto}_${port}")"
      elems4=$(make_elements "$f.c" 4); elems6=$(make_elements "$f.c" 6)
      [[ -n "$elems4" ]] && { echo "  set $set4 { type ipv4_addr; flags interval; elements = { $elems4 }; }"; }
      [[ -n "$elems6" ]] && { echo "  set $set6 { type ipv6_addr; flags interval; elements = { $elems6 }; }"; }
    done
    echo "  chain input {"
    if [[ "$FIREWALL_MODE" == port_only ]]; then
      echo "    type filter hook input priority 0; policy accept;"
    else
      echo "    type filter hook input priority 0; policy drop;"
    fi
    echo "    iif lo accept"
    if [[ "$FIREWALL_MODE" == global ]]; then
      echo "    ct state established,related accept"
      echo "    ip protocol icmp accept"
      echo "    ip6 nexthdr icmpv6 accept"
      sort -u "$tmpdir/allkeys" 2>/dev/null | while IFS='|' read -r mode port proto; do
        [[ -n "${mode:-}" ]] || continue
        f="$tmpdir/$mode|$port|$proto.c"; set4="allow4_$(sanitize_set "${mode}_${proto}_${port}")"; set6="allow6_$(sanitize_set "${mode}_${proto}_${port}")"
        elems4=$(make_elements "$f" 4); elems6=$(make_elements "$f" 6)
        if [[ "$mode" == all ]]; then
          [[ -n "$elems4" ]] && echo "    ip saddr @$set4 accept"
          [[ -n "$elems6" ]] && echo "    ip6 saddr @$set6 accept"
        else
          [[ -n "$elems4" ]] && echo "    ip saddr @$set4 $proto dport $port accept"
          [[ -n "$elems6" ]] && echo "    ip6 saddr @$set6 $proto dport $port accept"
        fi
      done
    else
      sort -u "$tmpdir/allkeys" 2>/dev/null | while IFS='|' read -r mode port proto; do
        [[ -n "${mode:-}" ]] || continue
        f="$tmpdir/$mode|$port|$proto.c"; set4="allow4_$(sanitize_set "${mode}_${proto}_${port}")"; set6="allow6_$(sanitize_set "${mode}_${proto}_${port}")"
        elems4=$(make_elements "$f" 4); elems6=$(make_elements "$f" 6)
        [[ -n "$elems4" ]] && echo "    ip saddr @$set4 $proto dport $port accept"
        [[ -n "$elems6" ]] && echo "    ip6 saddr @$set6 $proto dport $port accept"
      done
      sort -u "$tmpdir/allkeys" | while IFS='|' read -r mode port proto; do
        [[ -n "$mode" ]] || continue
        echo "    $proto dport $port drop"
      done
      echo "    ct state established,related accept"
      echo "    ip protocol icmp accept"
      echo "    ip6 nexthdr icmpv6 accept"
    fi
    echo "  }"
    echo "}"
  } > "$outtmp"
  chmod 0600 "$outtmp"
  mv "$outtmp" "$out"
  rm -rf "$tmpdir"
  echo -e "${GREEN}已生成：$out${NC}"
}

apply_ruleset(){
  local load_file
  generate_ruleset || return 1
  load_file=$(mktemp); register_temp "$load_file"

  if nft list table inet "$TABLE_NAME" >/dev/null 2>&1; then
    echo "delete table inet $TABLE_NAME" > "$load_file"
  fi
  cat "$RULESET_FILE" >> "$load_file"

  if ! nft -c -f "$load_file"; then
    echo -e "${RED}规则语法检查失败，未修改当前防火墙。${NC}"
    rm -f "$load_file"
    return 1
  fi
  if ! nft -f "$load_file"; then
    echo -e "${RED}规则批次应用失败；nftables 未提交该批次，旧规则保持不变。${NC}"
    return 1
  fi
  rm -f "$load_file"
  echo -e "${GREEN}规则已应用。${NC}"
}

sync_persistence_if_installed(){
  if [[ -e "$PERSISTENCE_FILE" || -L "$PERSISTENCE_FILE" ]]; then
    atomic_copy "$RULESET_FILE" "$PERSISTENCE_FILE" || return 1
    echo -e "${GREEN}已同步持久化文件：$PERSISTENCE_FILE${NC}"
  fi
}

auto_apply_after_change(){
  if managed_unit && ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo -e "${YELLOW}白名单服务当前已停止，更新规则文件但不立即应用。${NC}"
    if generate_ruleset; then sync_persistence_if_installed; else return 1; fi
    return 0
  fi
  echo -e "${BLUE}检测到白名单变更，正在自动生成并应用规则...${NC}"
  if apply_ruleset; then
    sync_persistence_if_installed
  else
    echo -e "${YELLOW}分组数据已保存。请修复问题后使用菜单 10 重新应用。${NC}"
    return 1
  fi
}
show_nft(){ nft list table inet "$TABLE_NAME" 2>/dev/null || echo -e "${YELLOW}当前未找到 table inet $TABLE_NAME${NC}"; }
show_counts(){ local total=0 g c; for g in $(list_groups || true); do c=$(wc -l < "$(group_file "$g")" 2>/dev/null | tr -d ' ' || echo 0); printf '%s: %s\n' "$g" "$c"; total=$((total+c)); done; echo "总计分组内 CIDR 条目：$total"; }

start_whitelist_service(){
  if ! managed_unit; then
    echo -e "${YELLOW}尚未安装持久化服务，请先执行菜单 15。${NC}"
    return 1
  fi
  generate_ruleset || return 1
  atomic_copy "$RULESET_FILE" "$PERSISTENCE_FILE" || return 1
  systemctl daemon-reload
  if systemctl restart "$SERVICE_NAME"; then
    echo -e "${GREEN}白名单服务已启动，规则已生效。${NC}"
  else
    echo -e "${RED}白名单服务启动失败，请检查：systemctl status $SERVICE_NAME${NC}"
    return 1
  fi
}

stop_whitelist_service(){
  if managed_unit; then
    systemctl stop "$SERVICE_NAME" || return 1
  elif [[ -e "$UNIT_FILE" || -L "$UNIT_FILE" ]]; then
    echo -e "${RED}检测到非本脚本管理的同名 systemd 单元，拒绝停止或删除规则。${NC}"
    return 1
  else
    nft delete table inet "$TABLE_NAME" 2>/dev/null || true
  fi
  echo -e "${GREEN}白名单服务已停止，table inet $TABLE_NAME 已移除，白名单拦截规则暂不生效。${NC}"
}

restart_whitelist_service(){
  stop_whitelist_service
  start_whitelist_service
}

install_persistence(){
  local unit_file="$UNIT_FILE"
  local persist_dir cur
  persist_dir=$(dirname "$PERSISTENCE_FILE"); cur="$persist_dir"
  while [[ "$cur" != "/" ]]; do
    [[ ! -L "$cur" ]] || { echo -e "${RED}持久化目录包含符号链接，拒绝操作：$cur${NC}"; return 1; }
    cur=$(dirname "$cur")
  done
  [[ ! -L "$PERSISTENCE_FILE" && ! -L "$unit_file" ]] || { echo -e "${RED}持久化目标是符号链接，拒绝写入。${NC}"; return 1; }
  if [[ -e "$unit_file" || -L "$unit_file" ]] && ! managed_unit; then
    echo -e "${RED}拒绝覆盖已有的非本脚本 systemd 单元：$unit_file${NC}"
    return 1
  fi
  if managed_unit; then
    echo "开机持久化当前：$(persistence_state)"
    echo "1) 启用/更新开机持久化"
    echo "2) 关闭开机持久化（保留配置）"
    echo "0) 返回"
    local action
    read -rp "选择：" action
    case "$action" in
      1) ;;
      2)
        local confirm
        read -rp "关闭后本脚本白名单不会在开机恢复，且当前拦截规则会移除。确认？[y/N]：" confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return 0
        systemctl disable --now "$SERVICE_NAME" || return 1
        echo -e "${GREEN}开机持久化已关闭，服务定义和规则文件已保留。${NC}"
        return 0;;
      0) return 0;;
      *) echo -e "${RED}无效选择。${NC}"; return 1;;
    esac
  fi
  if ! apply_ruleset; then
    echo -e "${RED}当前规则检查或应用失败，未安装持久化。${NC}"
    return 1
  fi

  mkdir -p "$(dirname "$PERSISTENCE_FILE")"
  atomic_copy "$RULESET_FILE" "$PERSISTENCE_FILE" || return 1
  local unit_tmp
  unit_tmp=$(mktemp /etc/systemd/system/.ipmgr-nft.service.XXXXXX) || return 1
  register_temp "$unit_tmp"
  cat > "$unit_tmp" <<'EOF'
[Unit]
# Generated by nft-ipset-manager
Description=IP Manager nftables whitelist
After=network-pre.target
Before=network.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/nft delete table inet ipmgr
ExecStart=/usr/sbin/nft -f /etc/nftables.d/ipmgr.nft
ExecReload=/bin/sh -c '/usr/sbin/nft delete table inet ipmgr 2>/dev/null || true; /usr/sbin/nft -f /etc/nftables.d/ipmgr.nft'
ExecStop=-/usr/sbin/nft delete table inet ipmgr

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$unit_tmp"
  mv -f "$unit_tmp" "$unit_file"

  systemctl daemon-reload
  systemctl enable ipmgr-nft.service
  if ! systemctl restart ipmgr-nft.service; then
    echo -e "${RED}ipmgr-nft 服务启动失败，请检查：systemctl status ipmgr-nft.service${NC}"
    return 1
  fi
  echo -e "${GREEN}已安装独立开机持久化服务：$SERVICE_NAME${NC}"
  echo -e "${GREEN}未覆盖 /etc/nftables.conf，不影响系统其他 nftables 配置。${NC}"
  echo -e "${GREEN}以后可用菜单 12/13/14 启动、停止、重启白名单服务。${NC}"
}

init_firewall(){
  if managed_unit && [[ "$(service_state)" == "已停止" ]]; then
    echo -e "${YELLOW}白名单服务当前已停止，请使用菜单 12 启动服务后再应用规则。${NC}"
    return 0
  fi
  if [[ "$FIREWALL_MODE" == port_only ]]; then
    echo -e "${YELLOW}当前为“仅限制已配置端口”模式，只会拦截已配置端口。${NC}"
  else
    echo -e "${RED}警告：本脚本生成的 table inet ipmgr 默认 policy drop。${NC}"
    echo -e "${YELLOW}请先把当前 SSH IP 加入一个允许默认端口的分组，并应用规则。${NC}"
  fi
  read -rp "确认仍要生成并应用当前分组规则？[y/N]：" ok; [[ "$ok" =~ ^[Yy]$ ]] || return
  apply_ruleset
}

show_cache(){ echo -e "${BLUE}wl/：${NC}"; find "$WL_DIR" -maxdepth 1 -type f -printf '%f\t%k KB\n' 2>/dev/null | sort || true; echo -e "${BLUE}bd/：${NC}"; find "$BD_DIR" -maxdepth 1 -type f -printf '%f\t%k KB\n' 2>/dev/null | sort || true; }
clean_cache(){ local c ok; show_cache; echo "1) 清理 wl  2) 清理 bd  3) 全部"; read -rp "选择：" c; read -rp "确认清理缓存？[y/N]：" ok; [[ "$ok" =~ ^[Yy]$ ]] || return; [[ "$c" == 1 || "$c" == 3 ]] && find "$WL_DIR" -maxdepth 1 -type f -delete; [[ "$c" == 2 || "$c" == 3 ]] && find "$BD_DIR" -maxdepth 1 -type f -delete; echo -e "${GREEN}缓存已清理。${NC}"; }
set_default_port(){ local p; p=$(ask_port "请输入默认端口：")||return; DEFAULT_PORT="$p"; save_config; }
show_port_mode_help(){
  echo -e "${BLUE}当前模式：仅限制已配置端口${NC}"
  echo "新建或导入分组时，需要为该组指定端口和 TCP/UDP 协议。"
  echo "未配置端口由系统其他防火墙规则处理；旧的全端口分组不会加载。"
  echo "如需为 SSH/IP 添加允许项，请使用菜单 4 或 5，并输入对应 SSH 端口。"
}
set_menu_shortcut(){
  local name path old_path quoted
  path="/usr/local/bin"
  [[ ! -L /usr/local && ! -L "$path" ]] || { echo -e "${RED}快捷命令目录存在符号链接，拒绝操作。${NC}"; return 1; }
  mkdir -p "$path"
  echo "当前脚本快捷键：${MENU_SHORTCUT:-未启用}"
  read -rp "输入快捷命令名（留空移除，输入 0 取消）：" name
  [[ "$name" == 0 ]] && return 0
  if [[ -z "$name" ]]; then
    if [[ -n "$MENU_SHORTCUT" && -f "$path/$MENU_SHORTCUT" ]] && [[ "$(sed -n '2p' "$path/$MENU_SHORTCUT")" == '# nft-ip-manager-shortcut' ]]; then
      rm -f "$path/$MENU_SHORTCUT"
    fi
    MENU_SHORTCUT=""
    save_config
    echo -e "${GREEN}脚本快捷键已移除。${NC}"
    return 0
  fi
  is_valid_shortcut "$name" || { echo -e "${RED}命令名须以字母开头，只能包含字母、数字、下划线和连字符（最多 32 位）。${NC}"; return 1; }
  if [[ -L "$path/$name" ]]; then
    echo -e "${RED}$path/$name 是符号链接，拒绝写入。${NC}"
    return 1
  fi
  if [[ -e "$path/$name" ]] && [[ "$(sed -n '2p' "$path/$name")" != '# nft-ip-manager-shortcut' ]]; then
    echo -e "${RED}$path/$name 已存在，不覆盖其他文件。${NC}"
    return 1
  fi
  printf -v quoted '%q' "$SCRIPT_PATH"
  {
    printf '#!/usr/bin/env bash\n# nft-ip-manager-shortcut\n'
    printf 'if [[ $EUID -eq 0 ]]; then\n  exec bash %s --menu\nelse\n  exec sudo bash %s --menu\nfi\n' "$quoted" "$quoted"
  } > "$path/$name"
  chmod 0755 "$path/$name"
  if [[ -n "$MENU_SHORTCUT" && "$MENU_SHORTCUT" != "$name" && -f "$path/$MENU_SHORTCUT" ]] && [[ "$(sed -n '2p' "$path/$MENU_SHORTCUT")" == '# nft-ip-manager-shortcut' ]]; then
    rm -f "$path/$MENU_SHORTCUT"
  fi
  MENU_SHORTCUT="$name"
  save_config
  echo -e "${GREEN}已设置脚本快捷键：$name（执行后打开管理菜单）${NC}"
}

set_firewall_mode(){
  local m confirm
  echo "请选择白名单管理范围："
  echo "1) 全局白名单：未匹配白名单的 TCP/UDP 新连接全部拒绝"
  echo "2) 仅限制已配置端口：只拦截已配置端口，其他端口交给系统规则"
  read -rp "选择 [1-2]：" m
  case "$m" in
    1)
      if [[ "$FIREWALL_MODE" == port_only ]]; then
        echo -e "${RED}切回全局白名单会拒绝未加入白名单的入站 TCP/UDP 新连接。请先确认 SSH IP 已在白名单中。${NC}"
        read -rp "确认切换并应用全局规则？[y/N]：" confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return 0
      fi
      FIREWALL_MODE="global";;
    2) FIREWALL_MODE="port_only";;
    *) echo -e "${RED}无效选择。${NC}"; return 1;;
  esac
  save_config
  echo -e "${GREEN}防火墙管理范围已更新。${NC}"
  if managed_unit || [[ "$(service_state)" == "运行中" ]]; then
    auto_apply_after_change
  fi
}

main_menu(){
  while true; do
    clear || true
    echo "========================================"
    echo " nftables set 白名单管理脚本 v8.3 (Debian 11/12/13)"
    echo " 基础目录：$BASE_DIR"
    if [[ "$FIREWALL_MODE" == global ]]; then
      echo " 默认端口：$DEFAULT_PORT"
    fi
    echo " 防火墙管理范围：$([[ "$FIREWALL_MODE" == port_only ]] && echo '仅限制已配置端口' || echo '全局白名单')"
    echo " 白名单服务状态：$(service_state)"
    echo " 开机持久化：$(persistence_state)"
    echo " 脚本快捷键：${MENU_SHORTCUT:-未启用}"
    echo "========================================"
    echo "1) 查看 nftables 当前规则"
    echo "2) 查看分组"
    echo "3) 查看分组数量统计"
    if [[ "$FIREWALL_MODE" == global ]]; then
      echo "4) 全局白名单：手动添加 IP/CIDR"
      echo "5) 全局白名单：添加当前 SSH 客户端 IPv4"
      echo "6) 全局白名单：从 URL 批量导入"
      echo "7) 全局白名单：从本地 txt 批量导入"
    else
      echo "4) 端口白名单：添加 IP/CIDR 并指定端口"
      echo "5) 端口白名单：添加当前 SSH 客户端 IPv4 并指定端口"
      echo "6) 端口白名单：导入 IP 并指定端口"
      echo "7) 端口白名单：导入 IP 并指定端口"
    fi
    echo "8) 从分组删除单个 IP/CIDR"
    echo "9) 删除分组"
    if [[ "$FIREWALL_MODE" == global ]]; then
      echo "10) 生成并应用全局白名单规则"
      echo "11) 生成全局白名单 ruleset"
    else
      echo "10) 生成并应用端口白名单规则"
      echo "11) 生成端口白名单 ruleset"
    fi
    echo "12) 启动白名单服务"
    echo "13) 停止白名单服务"
    echo "14) 重启白名单服务"
    echo "$(if managed_unit; then echo '15) 启用/关闭开机持久化'; else echo '15) 安装开机持久化'; fi)"
    echo "16) 初始化/应用防火墙"
    echo "17) 切换防火墙管理范围"
    if [[ "$FIREWALL_MODE" == global ]]; then
      echo "18) 设置默认端口"
    else
      echo "18) 端口白名单组管理说明"
    fi
    echo "19) 设置/移除脚本启动快捷键"
    echo "20) 检查/安装/更新必要依赖"
    echo "21) 查看缓存"
    echo "22) 清理缓存"
    echo "0) 退出"
    read -rp "请选择：" opt
    case "$opt" in
      1) show_nft || true; pause;;
      2) show_groups || true; pause;;
      3) show_counts || true; pause;;
      4) add_single_ip || true; pause;;
      5) auto_add_current_ip || true; pause;;
      6) add_group_from_url || true; pause;;
      7) add_group_from_local || true; pause;;
      8) delete_single_ip || true; pause;;
      9) delete_group || true; pause;;
      10)
        if managed_unit && [[ "$(service_state)" == "已停止" ]]; then
          echo -e "${YELLOW}白名单服务当前已停止，请使用菜单 12 启动服务后再应用规则。${NC}"
        else
          apply_ruleset || true
        fi
        pause;;
      11) generate_ruleset || true; pause;;
      12) start_whitelist_service || true; pause;;
      13) stop_whitelist_service || true; pause;;
      14) restart_whitelist_service || true; pause;;
      15) install_persistence || true; pause;;
      16) init_firewall || true; pause;;
      17) set_firewall_mode || true; pause;;
      18)
        if [[ "$FIREWALL_MODE" == global ]]; then set_default_port || true; else show_port_mode_help; fi
        pause;;
      19) set_menu_shortcut || true; pause;;
      20) manage_dependencies || true; pause;;
      21) show_cache || true; pause;;
      22) clean_cache || true; pause;;
      0) exit 0;;
      *) echo -e "${RED}无效选择。${NC}"; pause;;
    esac
  done
}

need_root
check_data_dirs
ensure_dirs
check_data_dirs
check_data_files
if command -v flock >/dev/null 2>&1; then
  exec 9>"$BASE_DIR/.manager.lock"
  flock -n 9 || { echo -e "${YELLOW}脚本已有另一个实例运行，已退出以避免并发修改。${NC}"; exit 1; }
fi
ensure_usage_doc
load_config
case "${1:-}" in
  --menu) main_menu; exit 0;;
esac
install_deps
main_menu
