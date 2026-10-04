#!/bin/sh
#======================================================================
# yt-dlp 网页一键脚本
#----------------------------------------------------------------------
# 在 Linux 小鸡上装好 yt-dlp 的网页，Mac 浏览器打开就能下 YouTube。
# 自动认出系统、架构、内存和硬盘，缺的组件从这台机器自己的软件源装。
# 软件源里没有的，再下官方静态程序。
#
# 不用 Docker。Docker 自己就占满 64MB，小小鸡起不来。
# 64MB 会先做一块硬盘上的虚拟内存，并让下载一个接一个跑，避免内存被打爆。
#
# 安装时会用大白话问端口、登录、一次下几个、Mac 怎么打开、视频放哪。
# 每一题直接回车就是推荐项。再运行一次会再问，回车就沿用原来的选择。
#
#   sh install.sh
#   sh install.sh --status
#   sh install.sh --reset-password
#   sh install.sh --uninstall
#======================================================================

VERSION=1.0.1
# ytdlp-onekey-begin

if [ -t 1 ]; then
  C_RED=$(printf '\033[0;31m')
  C_GREEN=$(printf '\033[0;32m')
  C_YELLOW=$(printf '\033[1;33m')
  C_BLUE=$(printf '\033[0;34m')
  C_NC=$(printf '\033[0m')
else
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_NC=''
fi

say_ok()   { printf '%s\n' "${C_GREEN}✓ $*${C_NC}"; }
say_info() { printf '%s\n' "${C_BLUE}$*${C_NC}"; }
say_warn() { printf '%s\n' "${C_YELLOW}! $*${C_NC}"; }
say_err()  { printf '%s\n' "${C_RED}✗ $*${C_NC}" >&2; }
say_step() { printf '\n%s\n' "${C_YELLOW}>>> $*${C_NC}"; }
die()      { say_err "$*"; exit 1; }

#----------------------------------------------------------------------
# 纯判断。测试会直接调用这些函数。
#----------------------------------------------------------------------

version_ge() {
  a=$(printf '%s\n' "$1" | sed 's/[^0-9.].*$//')
  b=$(printf '%s\n' "$2" | sed 's/[^0-9.].*$//')
  [ -n "$a" ] || return 1
  [ -n "$b" ] || return 1
  i=1
  while [ "$i" -le 3 ]; do
    pa=$(printf '%s\n' "$a" | cut -d. -f"$i" | sed 's/[^0-9].*$//; s/^0*//')
    pb=$(printf '%s\n' "$b" | cut -d. -f"$i" | sed 's/[^0-9].*$//; s/^0*//')
    [ -n "$pa" ] || pa=0
    [ -n "$pb" ] || pb=0
    if [ "$pa" -gt "$pb" ]; then return 0; fi
    if [ "$pa" -lt "$pb" ]; then return 1; fi
    i=$((i + 1))
  done
  return 0
}

version_newer() {
  version_ge "$1" "$2" || return 1
  version_ge "$2" "$1" && return 1
  return 0
}

version_from_file() {
  [ -f "$1" ] || return 1
  sed -n 's/^VERSION=\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "$1" | head -n 1
}

remote_script_ok() {
  file=$1
  [ -s "$file" ] || return 1
  head -n 1 "$file" | grep -q '^#!/bin/sh' || return 1
  ver=$(version_from_file "$file")
  [ -n "$ver" ] || return 1
  grep -q 'ytdlp-onekey-begin' "$file" || return 1
  sh -n "$file" >/dev/null 2>&1
}

arch_from_uname() {
  case "$1" in
    x86_64|amd64) printf '%s\n' amd64 ;;
    aarch64|arm64) printf '%s\n' arm64 ;;
    armv7l|armv7|armhf) printf '%s\n' armv7 ;;
    armv6l|armv6) printf '%s\n' armv6 ;;
    i386|i686|x86) printf '%s\n' 386 ;;
    *) printf '%s\n' unknown; return 1 ;;
  esac
}

webui_asset() {
  case "$1" in
    amd64) printf '%s\n' yt-dlp-webui_linux-amd64 ;;
    arm64) printf '%s\n' yt-dlp-webui_linux-arm64 ;;
    armv7) printf '%s\n' yt-dlp-webui_linux-armv7 ;;
    armv6) printf '%s\n' yt-dlp-webui_linux-armv6 ;;
    *) return 1 ;;
  esac
}

ytdlp_asset() {
  case "$1:$2" in
    amd64:glibc) printf '%s\n' yt-dlp_linux ;;
    amd64:musl) printf '%s\n' yt-dlp_musllinux ;;
    arm64:glibc) printf '%s\n' yt-dlp_linux_aarch64 ;;
    arm64:musl) printf '%s\n' yt-dlp_musllinux_aarch64 ;;
    armv7:glibc|armv7:musl|armv6:glibc|armv6:musl) printf '%s\n' yt-dlp_linux_armv7l.zip ;;
    *) return 1 ;;
  esac
}

qjs_asset() {
  case "$1" in
    amd64) printf '%s\n' qjs-linux-x86_64 ;;
    arm64) printf '%s\n' qjs-linux-aarch64 ;;
    armv7|armv6) printf '%s\n' qjs-linux-armv7 ;;
    386) printf '%s\n' qjs-linux-x86 ;;
    *) return 1 ;;
  esac
}

other_libc() {
  case "$1" in
    glibc) printf '%s\n' musl ;;
    musl) printf '%s\n' glibc ;;
    *) return 1 ;;
  esac
}

# 目标是凑够大约 768MB 可用内存，yt-dlp 解一个视频才不会被杀掉。
# 硬盘要留下 160MB 给程序本身。算出来的大小按 64MB 对齐。
swap_plan_mb() {
  ram=$1
  swap=$2
  free=$3
  case "$ram$swap$free" in
    *[!0-9]*) printf '%s\n' 0; return 0 ;;
  esac
  [ -n "$ram" ] && [ -n "$swap" ] && [ -n "$free" ] || { printf '%s\n' 0; return 0; }
  if [ "$ram" -ge 768 ]; then
    printf '%s\n' 0
    return 0
  fi
  have=$((ram + swap))
  if [ "$have" -ge 768 ]; then
    printf '%s\n' 0
    return 0
  fi
  need=$((768 - have))
  budget=$((free - 160))
  if [ "$budget" -lt 64 ]; then
    printf '%s\n' 0
    return 0
  fi
  if [ "$need" -gt "$budget" ]; then
    need=$budget
  fi
  need=$((need / 64 * 64))
  if [ "$need" -lt 64 ]; then
    need=0
  fi
  printf '%s\n' "$need"
}

queue_for() {
  ram=$1
  if [ -n "$ram" ] && [ "$ram" -lt 768 ]; then
    printf '%s\n' 1
  else
    printf '%s\n' 2
  fi
}

downloader_for() {
  ram=$1
  if [ -n "$ram" ] && [ "$ram" -lt 768 ]; then
    printf '%s\n' /usr/local/bin/yt-dlp-one
  else
    printf '%s\n' /usr/local/bin/yt-dlp
  fi
}

gomem_for() {
  ram=$1
  if [ -z "$ram" ]; then
    printf '\n'
    return 0
  fi
  if [ "$ram" -le 128 ]; then
    printf '%s\n' 48MiB
  elif [ "$ram" -le 512 ]; then
    printf '%s\n' 64MiB
  else
    printf '\n'
  fi
}

data_dir_for() {
  case "$1" in
    tmpfs|devtmpfs) printf '%s\n' /yt-dlp-webui-data ;;
    *) printf '%s\n' /var/lib/yt-dlp-webui ;;
  esac
}

pm_from_release() {
  blob=$(printf '%s %s' "$1" "$2" | tr 'A-Z' 'a-z')
  case "$blob" in
    *alpine*) printf '%s\n' apk ;;
    *openwrt*) printf '%s\n' opkg ;;
    *debian*|*ubuntu*|*raspbian*|*mint*|*kali*) printf '%s\n' apt ;;
    *fedora*|*rhel*|*centos*|*rocky*|*alma*|*amazon*) printf '%s\n' dnf ;;
    *arch*|*manjaro*) printf '%s\n' pacman ;;
    *suse*|*sles*) printf '%s\n' zypper ;;
    *void*) printf '%s\n' xbps ;;
    *) printf '%s\n' unknown; return 1 ;;
  esac
}

pkg_name() {
  case "$1:$2" in
    apt:curl|apk:curl|dnf:curl|yum:curl|pacman:curl|zypper:curl|opkg:curl|xbps:curl) printf '%s\n' curl ;;
    apt:ca|apk:ca|dnf:ca|yum:ca|pacman:ca|zypper:ca|opkg:ca|xbps:ca) printf '%s\n' ca-certificates ;;
    apt:tar|apk:tar|dnf:tar|yum:tar|pacman:tar|zypper:tar|opkg:tar|xbps:tar) printf '%s\n' tar ;;
    apt:xz) printf '%s\n' xz-utils ;;
    apk:xz|dnf:xz|yum:xz|pacman:xz|zypper:xz|opkg:xz|xbps:xz) printf '%s\n' xz ;;
    apt:unzip|apk:unzip|dnf:unzip|yum:unzip|pacman:unzip|zypper:unzip|opkg:unzip|xbps:unzip) printf '%s\n' unzip ;;
    apt:ffmpeg|apk:ffmpeg|dnf:ffmpeg|yum:ffmpeg|pacman:ffmpeg|zypper:ffmpeg|opkg:ffmpeg|xbps:ffmpeg) printf '%s\n' ffmpeg ;;
    apt:htpasswd|apk:htpasswd|zypper:htpasswd) printf '%s\n' apache2-utils ;;
    dnf:htpasswd|yum:htpasswd) printf '%s\n' httpd-tools ;;
    pacman:htpasswd) printf '%s\n' apache ;;
    apt:flock|apk:flock|dnf:flock|yum:flock|pacman:flock|zypper:flock|xbps:flock) printf '%s\n' util-linux ;;
    *) return 1 ;;
  esac
}

is_ipv4() {
  ip=${1%%/*}
  oldifs=$IFS
  IFS=.
  # shellcheck disable=SC2086
  set -- $ip
  IFS=$oldifs
  [ "$#" -eq 4 ] || return 1
  for n in "$1" "$2" "$3" "$4"; do
    case $n in
      ''|*[!0-9]*) return 1 ;;
    esac
    n=$(printf '%s' "$n" | sed 's/^0*//')
    [ -n "$n" ] || n=0
    [ "$n" -le 255 ] || return 1
  done
  return 0
}

is_private_ipv4() {
  is_ipv4 "$1" || return 1
  ip=${1%%/*}
  oldifs=$IFS
  IFS=.
  # shellcheck disable=SC2086
  set -- $ip
  IFS=$oldifs
  a=$(printf '%s' "$1" | sed 's/^0*//')
  b=$(printf '%s' "$2" | sed 's/^0*//')
  [ -n "$a" ] || a=0
  [ -n "$b" ] || b=0
  [ "$a" -eq 0 ] && return 0
  [ "$a" -eq 10 ] && return 0
  [ "$a" -eq 127 ] && return 0
  [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 0
  [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0
  if [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ]; then
    return 0
  fi
  if [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ]; then
    return 0
  fi
  return 1
}

is_global_ipv6() {
  case "$1" in
    ''|::1|fe80:*|FE80:*|fc*|FC*|fd*|FD*) return 1 ;;
    *:*) return 0 ;;
    *) return 1 ;;
  esac
}

libc_from_text() {
  printf '%s\n' "$1" | grep -q -i musl && { printf '%s\n' musl; return 0; }
  printf '%s\n' glibc
}

js_runtime_value() {
  kind=$1
  path=$2
  [ -n "$kind" ] && [ -n "$path" ] || return 1
  printf '%s:%s\n' "$kind" "$path"
}

write_config() {
  file=$1
  port=$2
  user=$3
  hash=$4
  dl=$5
  js=$6
  queue=$7
  data=$8
  down=$9
  [ -n "$file" ] && [ -n "$port" ] && [ -n "$user" ] && [ -n "$hash" ] || return 1
  [ -n "$down" ] || down="$data/downloads"
  {
    printf '%s\n' 'server:'
    printf '%s\n' '  host: "0.0.0.0"'
    printf '  port: %s\n' "$port"
    printf '  queue_size: %s\n' "$queue"
    printf '%s\n' 'paths:'
    printf '  download_path: "%s"\n' "$down"
    printf '  downloader_path: "%s"\n' "$dl"
    printf '  local_database_path: "%s"\n' "$data"
    printf '  js_runtime_path: "%s"\n' "$js"
    printf '%s\n' 'authentication:'
    printf '%s\n' '  require_auth: true'
    printf '  username: "%s"\n' "$user"
    printf '  password_hash: "%s"\n' "$hash"
    printf '%s\n' 'logging:'
    printf '%s\n' '  enable_file_logging: true'
    printf '  log_path: "%s"\n' '/var/log/yt-dlp-webui.log'
  } > "$file"
}

# 下面几个只判断输入对不对，不读键盘。
normalize_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  n=$(printf '%s' "$1" | sed 's/^0*//')
  [ -n "$n" ] || n=0
  printf '%s\n' "$n"
}

port_text_problem() {
  p=$(normalize_port "$1") || { printf '%s\n' nan; return 0; }
  if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
    printf '%s\n' range
    return 0
  fi
  if [ "$p" -eq 22 ]; then
    printf '%s\n' ssh
    return 0
  fi
  printf '%s\n' ok
}

user_text_problem() {
  u=$1
  case "$u" in
    ''|*[!A-Za-z0-9]*) printf '%s\n' chars; return 0 ;;
  esac
  if [ "${#u}" -gt 32 ]; then
    printf '%s\n' len
    return 0
  fi
  printf '%s\n' ok
}

pass_text_problem() {
  p=$1
  [ -n "$p" ] || { printf '%s\n' empty; return 0; }
  case "$p" in
    *[[:space:]]*) printf '%s\n' space; return 0 ;;
  esac
  if [ "${#p}" -lt 6 ]; then
    printf '%s\n' short
    return 0
  fi
  printf '%s\n' ok
}

dir_text_problem() {
  d=$1
  case "$d" in
    /*) ;;
    *) printf '%s\n' relative; return 0 ;;
  esac
  case "$d" in
    *[[:space:]]*) printf '%s\n' space; return 0 ;;
    *..*) printf '%s\n' dotdot; return 0 ;;
  esac
  if printf '%s' "$d" | grep -q '["\\]'; then
    printf '%s\n' symbol
    return 0
  fi
  case "$d" in
    /|/tmp|/tmp/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*)
      printf '%s\n' system
      return 0
      ;;
  esac
  printf '%s\n' ok
}

# 空答案用默认。不在 1 到 max 之间时打印 bad。
menu_answer() {
  a=$1
  d=$2
  max=$3
  a=$(printf '%s' "$a" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -z "$a" ] && a=$d
  case "$a" in
    ''|*[!0-9]*) printf '%s\n' bad; return 0 ;;
  esac
  n=$(printf '%s' "$a" | sed 's/^0*//')
  [ -n "$n" ] || n=0
  if [ "$n" -ge 1 ] && [ "$n" -le "$max" ]; then
    printf '%s\n' "$n"
  else
    printf '%s\n' bad
  fi
}

downloader_for_choice() {
  if [ "$1" = 2 ]; then
    printf '%s\n' /usr/local/bin/yt-dlp
  else
    printf '%s\n' /usr/local/bin/yt-dlp-one
  fi
}

fstab_append_line() {
  file=$1
  line=$2
  [ -n "$file" ] && [ -n "$line" ] || return 1
  if [ ! -e "$file" ]; then
    printf '%s\n' "$line" > "$file"
    return 0
  fi
  if grep -qxF "$line" "$file" 2>/dev/null; then
    return 0
  fi
  if grep -qF "$line" "$file" 2>/dev/null; then
    tmp=$(mktemp) || return 1
    if awk -v key="$line" '
      {
        i = index($0, key)
        if (i == 0) { print; next }
        if (i == 1) { print; next }
        pre = substr($0, 1, i - 1)
        if (pre != "") print pre
        print key
      }
    ' "$file" > "$tmp"; then
      cat "$tmp" > "$file"
    fi
    rm -f "$tmp"
    return 0
  fi
  if [ -s "$file" ] && [ -n "$(tail -c 1 "$file" 2>/dev/null)" ]; then
    printf '\n' >> "$file"
  fi
  printf '%s\n' "$line" >> "$file"
}

fstab_remove_line() {
  file=$1
  line=$2
  [ -f "$file" ] && [ -n "$line" ] || return 0
  tmp=$(mktemp) || return 1
  if awk -v key="$line" '
    {
      i = index($0, key)
      if (i == 0) { print; next }
      if (i == 1 && $0 == key) { next }
      if (i == 1) { print; next }
      pre = substr($0, 1, i - 1)
      if (pre != "") print pre
    }
  ' "$file" > "$tmp"; then
    cat "$tmp" > "$file"
  fi
  rm -f "$tmp"
}

shortcut_link_dir() {
  path=$1
  case ":$path:" in
    *:/usr/local/sbin:*)
      printf '\n'
      return 0
      ;;
  esac
  for dir in /usr/sbin /sbin /usr/bin /bin; do
    case ":$path:" in
      *:"$dir":*)
        printf '%s\n' "$dir"
        return 0
        ;;
    esac
  done
  printf '\n'
}

#----------------------------------------------------------------------
# 下面开始碰这台机器。
#----------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

read_meminfo_kb() {
  awk -v k="$1" '$1==k {print $2; exit}' /proc/meminfo 2>/dev/null
}

cgroup_mem_mb() {
  for cgf in /sys/fs/cgroup/memory.max \
             /sys/fs/cgroup/memory/memory.limit_in_bytes \
             /sys/fs/cgroup/memory.limit_in_bytes; do
    [ -r "$cgf" ] || continue
    cgv=$(tr -d ' \r\n' < "$cgf" 2>/dev/null)
    case "$cgv" in ''|max|*[!0-9]*) continue ;; esac
    [ "${#cgv}" -le 12 ] || continue
    [ "$cgv" -ge 1048576 ] || continue
    printf '%s' $((cgv / 1024 / 1024))
    return 0
  done
  return 1
}

disk_free_mb() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4/1024)}'
}

fstype_of() {
  awk -v m="$1" '$2==m {print $3; exit}' /proc/mounts 2>/dev/null
}

drop_page_cache() {
  sync
  if [ -w /proc/sys/vm/drop_caches ]; then
    { printf '3\n' > /proc/sys/vm/drop_caches; } 2>/dev/null || true
  fi
}

load_os() {
  OS_ID=unknown
  OS_VER=
  OS_LIKE=
  OS_PRETTY=Linux
  if [ -f /etc/os-release ]; then
    # 用函数里的 local，避免发行版文件里的变量漏到外面。
    # shellcheck disable=SC2039
    local ID VERSION_ID ID_LIKE PRETTY_NAME
    ID=
    VERSION_ID=
    ID_LIKE=
    PRETTY_NAME=
    # shellcheck disable=SC1091
    . /etc/os-release
    [ -n "$ID" ] && OS_ID=$ID
    OS_VER=$VERSION_ID
    OS_LIKE=$ID_LIKE
    [ -n "$PRETTY_NAME" ] && OS_PRETTY=$PRETTY_NAME
  elif [ -f /etc/openwrt_release ]; then
    OS_ID=openwrt
    OS_PRETTY=OpenWrt
  fi
}

detect_pm() {
  want=$(pm_from_release "$OS_ID" "$OS_LIKE" 2>/dev/null || true)
  case "$want" in
    apt) have apt-get && { PM=apt; return 0; } ;;
    apk) have apk && { PM=apk; return 0; } ;;
    dnf)
      if have dnf; then PM=dnf; return 0; fi
      if have yum; then PM=yum; return 0; fi
      ;;
    pacman) have pacman && { PM=pacman; return 0; } ;;
    zypper) have zypper && { PM=zypper; return 0; } ;;
    opkg) have opkg && { PM=opkg; return 0; } ;;
    xbps) have xbps-install && { PM=xbps; return 0; } ;;
  esac
  if have apt-get; then PM=apt; return 0; fi
  if have apk; then PM=apk; return 0; fi
  if have dnf; then PM=dnf; return 0; fi
  if have yum; then PM=yum; return 0; fi
  if have pacman; then PM=pacman; return 0; fi
  if have zypper; then PM=zypper; return 0; fi
  if have opkg; then PM=opkg; return 0; fi
  if have xbps-install; then PM=xbps; return 0; fi
  PM=none
  return 1
}

detect_libc() {
  probe=
  if have ldd; then
    probe=$(ldd /bin/sh 2>&1 || true)
  fi
  for f in /lib/ld-musl-x86_64.so.1 /lib/ld-musl-aarch64.so.1 /lib/ld-musl-armhf.so.1; do
    if [ -e "$f" ]; then
      probe="$probe musl"
    fi
  done
  LIBC=$(libc_from_text "$probe")
}

detect_init() {
  if [ -d /run/systemd/system ] && have systemctl; then
    INIT=systemd
    return 0
  fi
  if have rc-service || [ -d /run/openrc ]; then
    INIT=openrc
    return 0
  fi
  if [ -f /etc/openwrt_release ] && have procd; then
    INIT=procd
    return 0
  fi
  INIT=sysv
}

detect_machine() {
  load_os
  detect_pm || true
  ARCH=$(arch_from_uname "$(uname -m)") || ARCH=unknown
  detect_libc
  detect_init
  MEM_MB=
  tot_kb=$(read_meminfo_kb "MemTotal:")
  if [ -n "$tot_kb" ]; then
    MEM_MB=$((tot_kb / 1024))
  fi
  cg_mb=$(cgroup_mem_mb 2>/dev/null || true)
  if [ -n "$cg_mb" ]; then
    if [ -z "$MEM_MB" ] || [ "$cg_mb" -lt "$MEM_MB" ]; then
      MEM_MB=$cg_mb
    fi
  fi
  SWAP_MB=0
  swap_kb=$(read_meminfo_kb "SwapTotal:")
  if [ -n "$swap_kb" ]; then
    SWAP_MB=$((swap_kb / 1024))
  fi
  DISK_MB=$(disk_free_mb /)
  [ -n "$DISK_MB" ] || DISK_MB=0
  NCPU=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
  case "$NCPU" in
    ''|*[!0-9]*) NCPU=1 ;;
  esac
  DATA=$(data_dir_for "$(fstype_of /var)")
}

need_tool() {
  case "$1" in
    curl) have curl || have wget ;;
    ca)
      [ -f /etc/ssl/certs/ca-certificates.crt ] || [ -f /etc/ssl/cert.pem ] || [ -s /etc/ssl/certs/ca-bundle.crt ]
      ;;
    tar) have tar ;;
    xz) have xz || have unxz ;;
    unzip) have unzip ;;
    ffmpeg) have ffmpeg && have ffprobe ;;
    htpasswd) have htpasswd ;;
    flock) have flock ;;
    *) return 1 ;;
  esac
}

pm_update() {
  [ "$PM_UPDATED" = 1 ] && return 0
  say_info "正在更新软件源（$PM）…"
  case "$PM" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -qq || DEBIAN_FRONTEND=noninteractive apt-get update
      ;;
    apk) apk update ;;
    dnf) dnf makecache -y >/dev/null 2>&1 || true ;;
    yum) yum makecache -y >/dev/null 2>&1 || true ;;
    pacman) pacman -Sy --noconfirm ;;
    zypper) zypper --non-interactive refresh || true ;;
    opkg) opkg update ;;
    xbps) xbps-install -S ;;
    *) return 1 ;;
  esac
  PM_UPDATED=1
}

pm_install_one() {
  pkg=$1
  [ -n "$pkg" ] || return 1
  [ "$PM" = none ] && return 1
  pm_update || return 1
  say_info "安装 $pkg"
  case "$PM" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg"
      rm -f /var/cache/apt/archives/*.deb 2>/dev/null || true
      ;;
    apk) apk add --no-cache "$pkg" ;;
    dnf) dnf install -y "$pkg" ;;
    yum) yum install -y "$pkg" ;;
    pacman) pacman -S --noconfirm --needed "$pkg" ;;
    zypper) zypper --non-interactive install --no-recommends "$pkg" ;;
    opkg) opkg install "$pkg" ;;
    xbps) xbps-install -y "$pkg" ;;
    *) return 1 ;;
  esac
  drop_page_cache
}

ensure_tool() {
  what=$1
  if need_tool "$what"; then
    return 0
  fi
  pkg=$(pkg_name "$PM" "$what" 2>/dev/null || true)
  if [ -z "$pkg" ]; then
    return 1
  fi
  pm_install_one "$pkg" || return 1
  need_tool "$what"
}

prepare_memory() {
  LOW_MEM=0
  if [ -n "$MEM_MB" ] && [ "$MEM_MB" -le 512 ]; then
    LOW_MEM=1
  fi
  if [ -w /proc/sys/vm/overcommit_memory ] && [ "$LOW_MEM" = 1 ]; then
    oc=$(tr -d ' \r\n' < /proc/sys/vm/overcommit_memory 2>/dev/null || true)
    if [ "$oc" != 1 ]; then
      if sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 \
        || printf '1\n' > /proc/sys/vm/overcommit_memory 2>/dev/null; then
        mkdir -p /etc/sysctl.d 2>/dev/null || true
        printf 'vm.overcommit_memory=1\n' > /etc/sysctl.d/99-yt-dlp-webui-overcommit.conf 2>/dev/null || true
        say_ok "小内存机器已放开内存申请限制"
      fi
    fi
  fi
  plan=$(swap_plan_mb "${MEM_MB:-0}" "${SWAP_MB:-0}" "${DISK_MB:-0}")
  if [ "$plan" -eq 0 ]; then
    if [ -n "$MEM_MB" ] && [ "$MEM_MB" -lt 256 ] && [ "${SWAP_MB:-0}" -lt 64 ]; then
      say_warn "内存大约 ${MEM_MB}MB，磁盘只剩 ${DISK_MB}MB，腾不出虚拟内存。安装会继续，下载视频时有可能被系统杀掉。"
    fi
    return 0
  fi
  root_type=$(fstype_of /)
  case "$root_type" in
    tmpfs|devtmpfs)
      say_warn "系统盘在内存里，没法再加虚拟内存"
      return 0
      ;;
  esac
  swapf=/yt-dlp-webui.swap
  if [ -f "$swapf" ]; then
    swapoff "$swapf" >/dev/null 2>&1 || true
    rm -f "$swapf"
  fi
  say_info "内存大约 ${MEM_MB:-很少}MB。正在做 ${plan}MB 虚拟内存，下载视频时用得上…"
  if ! dd if=/dev/zero of="$swapf" bs=1048576 count="$plan" >/dev/null 2>&1; then
    rm -f "$swapf"
    say_warn "虚拟内存文件没写成，继续安装"
    return 0
  fi
  chmod 600 "$swapf" 2>/dev/null || true
  if mkswap "$swapf" >/dev/null 2>&1 && swapon "$swapf" >/dev/null 2>&1; then
    fstab_append_line /etc/fstab "$swapf none swap sw 0 0"
    mkdir -p /etc/yt-dlp-webui
    printf '%s\n' "$plan" > /etc/yt-dlp-webui/swap.size
    SWAP_MB=$((SWAP_MB + plan))
    DISK_MB=$(disk_free_mb /)
    say_ok "虚拟内存已打开（${plan}MB），重启后也会自动挂上"
  else
    rm -f "$swapf"
    say_warn "这台机器不允许打开虚拟内存。安装会继续，下载时会尽量省内存。"
  fi
}

fetch_first() {
  dest=$1
  shift
  for url in "$@"; do
    rm -f "$dest"
    say_info "下载 $url"
    if have curl; then
      if curl -fL --retry 2 --connect-timeout 20 --max-time 300 -o "$dest" "$url" && [ -s "$dest" ]; then
        return 0
      fi
    elif have wget; then
      if wget -O "$dest" "$url" && [ -s "$dest" ]; then
        return 0
      fi
    else
      return 1
    fi
  done
  rm -f "$dest"
  return 1
}

github_urls() {
  path=$1
  printf '%s\n' "https://github.com/$path" "https://ghfast.top/https://github.com/$path"
}

file_magic() {
  od -An -tx1 -N 4 "$1" 2>/dev/null | tr -d ' \n' | tr 'A-F' 'a-f'
}

is_elf() { [ "$(file_magic "$1")" = "7f454c46" ]; }
is_zip() { [ "$(file_magic "$1")" = "504b0304" ]; }

rand_hex() {
  n=$1
  if od -An -tx1 -N "$n" /dev/urandom >/dev/null 2>&1; then
    od -An -tx1 -N "$n" /dev/urandom | tr -d ' \n'
    return 0
  fi
  return 1
}

latest_tag() {
  repo=$1
  body=
  if have curl; then
    body=$(curl -fsSL --connect-timeout 15 --max-time 25 "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null || true)
  elif have wget; then
    body=$(wget -qO- "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null || true)
  fi
  printf '%s\n' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

# 64MB 小鸡的 /tmp 经常是一块很小的内存盘，40MB 的 yt-dlp 放不进去。
workdir_for() {
  kind=$1
  free=$2
  case "$free" in
    ''|*[!0-9]*) free=0 ;;
  esac
  case "$kind" in
    tmpfs|devtmpfs) printf '%s\n' /yt-dlp-webui-work ;;
    *)
      if [ "$free" -lt 120 ]; then
        printf '%s\n' /yt-dlp-webui-work
      else
        printf '%s\n' /tmp/yt-dlp-webui-work
      fi
      ;;
  esac
}

prepare_workdir() {
  WORK=$(workdir_for "$(fstype_of /tmp)" "$(disk_free_mb /tmp)")
  rm -rf "$WORK"
  mkdir -p "$WORK"
}

install_static_ffmpeg() {
  case "$ARCH" in
    amd64) name=ffmpeg-release-amd64-static.tar.xz ;;
    arm64) name=ffmpeg-release-arm64-static.tar.xz ;;
    *) return 1 ;;
  esac
  free_now=$(disk_free_mb /)
  [ -n "$free_now" ] || free_now=0
  if [ "$free_now" -lt 220 ]; then
    say_warn "磁盘只剩 ${free_now}MB，装不下备用的 ffmpeg"
    return 1
  fi
  ensure_tool xz || true
  if ! need_tool xz; then
    return 1
  fi
  tmp=$WORK/ffmpeg-static.tar.xz
  dir=$WORK/ffmpeg-static-unpack
  rm -rf "$dir"
  mkdir -p "$dir"
  if ! fetch_first "$tmp" "https://johnvansickle.com/ffmpeg/releases/$name"; then
    rm -f "$tmp"
    return 1
  fi
  if ! xz -dc "$tmp" | tar -xf - -C "$dir"; then
    rm -rf "$dir" "$tmp"
    return 1
  fi
  rm -f "$tmp"
  ff=$(find "$dir" -type f -name ffmpeg | head -n 1)
  fp=$(find "$dir" -type f -name ffprobe | head -n 1)
  if [ -z "$ff" ] || [ -z "$fp" ] || ! is_elf "$ff"; then
    rm -rf "$dir"
    return 1
  fi
  cp "$ff" /usr/local/bin/ffmpeg
  cp "$fp" /usr/local/bin/ffprobe
  chmod 755 /usr/local/bin/ffmpeg /usr/local/bin/ffprobe
  mkdir -p /etc/yt-dlp-webui
  printf '%s\n' static > /etc/yt-dlp-webui/ffmpeg-static
  rm -rf "$dir"
  need_tool ffmpeg
}

ensure_ffmpeg() {
  if need_tool ffmpeg; then
    say_ok "ffmpeg 已经有了"
    return 0
  fi
  say_step "安装 ffmpeg（合并视频和音频要用）"
  if ensure_tool ffmpeg; then
    say_ok "ffmpeg 已从系统软件源装上"
    return 0
  fi
  say_info "软件源里没有 ffmpeg，改下静态版本"
  if install_static_ffmpeg; then
    say_ok "已装上静态 ffmpeg"
    return 0
  fi
  say_warn "ffmpeg 没装上。只能下那些不用合并的画质，高画质会失败。"
  return 0
}

place_elf() {
  src=$1
  dest=$2
  is_elf "$src" || return 1
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  chmod 755 "$dest"
}

install_qjs() {
  say_step "安装 QuickJS（YouTube 现在要它来算签名）"
  if [ -x /usr/local/bin/qjs ] && /usr/local/bin/qjs -e 'print(1)' >/dev/null 2>&1; then
    JS_RUNTIME=$(js_runtime_value quickjs /usr/local/bin/qjs)
    say_ok "QuickJS 已经能用，跳过下载"
    return 0
  fi
  asset=$(qjs_asset "$ARCH") || die "这个架构（$ARCH）没有 QuickJS，YouTube 下不了。"
  tag=$(latest_tag quickjs-ng/quickjs)
  [ -n "$tag" ] || tag=v0.17.0
  tmp=$WORK/qjs.new
  # shellcheck disable=SC2046
  if ! fetch_first "$tmp" $(github_urls "quickjs-ng/quickjs/releases/download/$tag/$asset"); then
    if [ "$tag" != v0.17.0 ]; then
      # shellcheck disable=SC2046
      fetch_first "$tmp" $(github_urls "quickjs-ng/quickjs/releases/download/v0.17.0/$asset") || true
    fi
  fi
  if ! is_elf "$tmp"; then
    rm -f "$tmp"
    die "QuickJS 下载下来不是程序。请检查这台鸡能不能打开 GitHub。"
  fi
  if ! "$tmp" -e 'print(1)' >/dev/null 2>&1; then
    rm -f "$tmp"
    die "QuickJS 在这台鸡上跑不起来。"
  fi
  place_elf "$tmp" /usr/local/bin/qjs
  rm -f "$tmp"
  JS_RUNTIME=$(js_runtime_value quickjs /usr/local/bin/qjs)
  say_ok "QuickJS 已放好"
}

ytdlp_try_asset() {
  asset=$1
  tmp=$WORK/yt-dlp.part
  # shellcheck disable=SC2046
  fetch_first "$tmp" $(github_urls "yt-dlp/yt-dlp/releases/latest/download/$asset") || return 1
  if is_zip "$tmp"; then
    ensure_tool unzip || die "这个架构的 yt-dlp 是压缩包，但这台鸡装不上 unzip。"
    unpack=$WORK/yt-dlp-unpack
    rm -rf "$unpack"
    mkdir -p "$unpack"
    unzip -o -q "$tmp" -d "$unpack" || return 1
    rm -f "$tmp"
    found=$(find "$unpack" -type f -name 'yt-dlp*' | head -n 1)
    [ -n "$found" ] || return 1
    mv "$found" "$tmp"
    rm -rf "$unpack"
  fi
  is_elf "$tmp" || return 1
  cp "$tmp" /usr/local/bin/yt-dlp
  chmod 755 /usr/local/bin/yt-dlp
  rm -f "$tmp"
  if ! /usr/local/bin/yt-dlp --version >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

install_ytdlp() {
  say_step "安装 yt-dlp"
  asset=$(ytdlp_asset "$ARCH" "$LIBC" 2>/dev/null || true)
  [ -n "$asset" ] || die "没有适合这台鸡的 yt-dlp（架构 $ARCH，库 $LIBC）。"
  if ytdlp_try_asset "$asset"; then
    say_ok "yt-dlp 已装上（$(/usr/local/bin/yt-dlp --version 2>/dev/null | head -n 1)）"
    return 0
  fi
  alt=$(other_libc "$LIBC" || true)
  alt_asset=$(ytdlp_asset "$ARCH" "$alt" 2>/dev/null || true)
  if [ -n "$alt_asset" ] && [ "$alt_asset" != "$asset" ]; then
    say_warn "第一个 yt-dlp 跑不起来，换 $alt 版本再试"
    if ytdlp_try_asset "$alt_asset"; then
      say_ok "yt-dlp 已装上"
      return 0
    fi
  fi
  die "yt-dlp 跑不起来。架构 $ARCH，系统库 $LIBC，内存大约 ${MEM_MB:-未知}MB。"
}

install_webui() {
  say_step "安装网页程序"
  asset=$(webui_asset "$ARCH") || die "这个网页程序没有 $ARCH 版本。32 位小鸡装不了。"
  tag=$(latest_tag marcopiovanello/yt-dlp-web-ui)
  [ -n "$tag" ] || tag=v4.0.0
  tmp=$WORK/yt-dlp-webui.new
  # shellcheck disable=SC2046
  if ! fetch_first "$tmp" $(github_urls "marcopiovanello/yt-dlp-web-ui/releases/download/$tag/$asset"); then
    if [ "$tag" != v4.0.0 ]; then
      # shellcheck disable=SC2046
      fetch_first "$tmp" $(github_urls "marcopiovanello/yt-dlp-web-ui/releases/download/v4.0.0/$asset") || true
    fi
  fi
  if ! is_elf "$tmp"; then
    rm -f "$tmp"
    die "网页程序下载失败。请检查这台鸡能不能打开 GitHub。"
  fi
  place_elf "$tmp" /usr/local/bin/yt-dlp-webui
  rm -f "$tmp"
  say_ok "网页程序已放好（$tag）"
}

write_one_wrapper() {
  cat > /usr/local/bin/yt-dlp-one <<'EOF'
#!/bin/sh
# 小内存机器一次只跑一个 yt-dlp。网页如果排了两个，第二个在这里等着。
export TMPDIR="${TMPDIR:-/var/lib/yt-dlp-webui/tmp}"
export HOME="${HOME:-/var/lib/yt-dlp-webui/home}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/var/lib/yt-dlp-webui/cache}"
mkdir -p "$TMPDIR" "$HOME" "$XDG_CACHE_HOME" 2>/dev/null || true
lock=${YTD_LOCK:-/var/lib/yt-dlp-webui/download.lock}
exec flock "$lock" /usr/local/bin/yt-dlp "$@"
EOF
  # 数据目录如果因为 /var 在内存里换了地方，锁也跟着走。
  if [ "$DATA" != /var/lib/yt-dlp-webui ]; then
    sed "s#/var/lib/yt-dlp-webui#$DATA#g" /usr/local/bin/yt-dlp-one > "$WORK/yt-dlp-one.new"
    mv "$WORK/yt-dlp-one.new" /usr/local/bin/yt-dlp-one
  fi
  chmod 755 /usr/local/bin/yt-dlp-one
}

write_runner() {
  cat > /usr/local/sbin/yt-dlp-webui-run <<EOF
#!/bin/sh
set -a
[ -f /etc/yt-dlp-webui/env ] && . /etc/yt-dlp-webui/env
set +a
export TMPDIR="$DATA/tmp"
export HOME="$DATA/home"
export XDG_CACHE_HOME="$DATA/cache"
mkdir -p "\$TMPDIR" "\$HOME" "\$XDG_CACHE_HOME" "$DATA/downloads"
cd "$DATA" || exit 1
exec /usr/local/bin/yt-dlp-webui --conf /etc/yt-dlp-webui/config.yml
EOF
  chmod 755 /usr/local/sbin/yt-dlp-webui-run
}

write_env_file() {
  secret=$1
  gomem=$2
  umask 077
  {
    printf 'JWT_SECRET=%s\n' "$secret"
    if [ -n "$gomem" ]; then
      printf 'GOMEMLIMIT=%s\n' "$gomem"
    fi
  } > /etc/yt-dlp-webui/env
  chmod 600 /etc/yt-dlp-webui/env
  umask 022
}

env_get() {
  key=$1
  [ -f /etc/yt-dlp-webui/env ] || return 1
  sed -n "s/^${key}=//p" /etc/yt-dlp-webui/env | head -n 1
}

config_get() {
  key=$1
  file=${2:-${YTD_CONFIG_FILE:-/etc/yt-dlp-webui/config.yml}}
  [ -f "$file" ] || return 1
  sed -n "s/^  ${key}: //p" "$file" | head -n 1 | sed 's/^"//; s/"$//'
}

write_service() {
  case "$INIT" in
    systemd)
      cat > /etc/systemd/system/yt-dlp-webui.service <<EOF
[Unit]
Description=yt-dlp web ui
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/yt-dlp-webui-run
WorkingDirectory=$DATA
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable yt-dlp-webui >/dev/null 2>&1 || true
      ;;
    openrc)
      cat > /etc/init.d/yt-dlp-webui <<EOF
#!/sbin/openrc-run
name="yt-dlp-webui"
description="yt-dlp web ui"
command="/usr/local/sbin/yt-dlp-webui-run"
command_background=true
pidfile="/run/yt-dlp-webui.pid"
directory="$DATA"
output_log="/var/log/yt-dlp-webui.service.log"
error_log="/var/log/yt-dlp-webui.service.log"

depend() {
  need net
}
EOF
      chmod 755 /etc/init.d/yt-dlp-webui
      rc-update add yt-dlp-webui default >/dev/null 2>&1 || true
      ;;
    procd)
      cat > /etc/init.d/yt-dlp-webui <<'EOF'
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
start_service() {
  procd_open_instance
  procd_set_param command /usr/local/sbin/yt-dlp-webui-run
  procd_set_param respawn 3600 5 0
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF
      chmod 755 /etc/init.d/yt-dlp-webui
      /etc/init.d/yt-dlp-webui enable >/dev/null 2>&1 || true
      ;;
    *)
      cat > /etc/init.d/yt-dlp-webui <<'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          yt-dlp-webui
# Required-Start:    $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: yt-dlp web ui
### END INIT INFO
PIDFILE=/run/yt-dlp-webui.pid
LOG=/var/log/yt-dlp-webui.service.log
case "$1" in
  start)
    mkdir -p /run
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
      exit 0
    fi
    /usr/local/sbin/yt-dlp-webui-run >> "$LOG" 2>&1 &
    echo $! > "$PIDFILE"
    ;;
  stop)
    if [ -f "$PIDFILE" ]; then
      kill "$(cat "$PIDFILE")" 2>/dev/null || true
      rm -f "$PIDFILE"
    fi
    ;;
  restart)
    "$0" stop
    "$0" start
    ;;
  *)
    echo "usage: $0 {start|stop|restart}" >&2
    exit 1
    ;;
esac
EOF
      chmod 755 /etc/init.d/yt-dlp-webui
      if [ -f /etc/rc.local ]; then
        if ! grep -q 'yt-dlp-webui-run' /etc/rc.local 2>/dev/null; then
          if [ -s /etc/rc.local ] && [ -n "$(tail -c 1 /etc/rc.local 2>/dev/null)" ]; then
            printf '\n' >> /etc/rc.local
          fi
          printf '%s\n' '/etc/init.d/yt-dlp-webui start' >> /etc/rc.local
        fi
        chmod +x /etc/rc.local 2>/dev/null || true
      fi
      if have update-rc.d; then
        update-rc.d yt-dlp-webui defaults >/dev/null 2>&1 || true
      elif have chkconfig; then
        chkconfig --add yt-dlp-webui >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

stop_service() {
  case "$INIT" in
    systemd) systemctl stop yt-dlp-webui >/dev/null 2>&1 || true ;;
    openrc) rc-service yt-dlp-webui stop >/dev/null 2>&1 || true ;;
    procd) [ -x /etc/init.d/yt-dlp-webui ] && /etc/init.d/yt-dlp-webui stop >/dev/null 2>&1 || true ;;
    *) [ -x /etc/init.d/yt-dlp-webui ] && /etc/init.d/yt-dlp-webui stop >/dev/null 2>&1 || true ;;
  esac
  if [ -f /run/yt-dlp-webui.pid ]; then
    kill "$(cat /run/yt-dlp-webui.pid)" >/dev/null 2>&1 || true
    rm -f /run/yt-dlp-webui.pid
  fi
}

start_service() {
  case "$INIT" in
    systemd) systemctl restart yt-dlp-webui ;;
    openrc) rc-service yt-dlp-webui restart ;;
    procd) /etc/init.d/yt-dlp-webui restart || /etc/init.d/yt-dlp-webui start ;;
    *) /etc/init.d/yt-dlp-webui restart || /etc/init.d/yt-dlp-webui start ;;
  esac
}

port_busy() {
  port=$1
  if have ss; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"
    return $?
  fi
  if have netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}$"
    return $?
  fi
  return 1
}

# 我们自己的网页占着这个端口时，更新可以继续用它。别的程序占着就不行。
port_taken_by_other() {
  port=$1
  port_busy "$port" || return 1
  if have ss; then
    info=$(ss -ltnp 2>/dev/null | grep -E ":${port}([^0-9]|$)" || true)
    if [ -n "$info" ]; then
      if printf '%s\n' "$info" | grep -q 'yt-dlp-webui'; then
        return 1
      fi
      if printf '%s\n' "$info" | grep -q 'users:'; then
        return 0
      fi
    fi
  fi
  old=$(config_get port 2>/dev/null || true)
  [ "$port" = "$old" ] && return 1
  return 0
}

health_ok() {
  port=$1
  i=0
  while [ "$i" -lt 20 ]; do
    code=000
    if have curl; then
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${port}/" 2>/dev/null || true)
    elif have wget; then
      wget -q -O /dev/null "http://127.0.0.1:${port}/" && code=200
    fi
    case "$code" in
      200|301|302|401) return 0 ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  return 1
}

show_fail_log() {
  say_err "网页没有起来。最近的记录："
  if have journalctl; then
    journalctl -u yt-dlp-webui -n 40 --no-pager 2>/dev/null || true
  fi
  if [ -f /var/log/yt-dlp-webui.service.log ]; then
    tail -n 40 /var/log/yt-dlp-webui.service.log 2>/dev/null || true
  fi
  if [ -f /var/log/yt-dlp-webui.log ]; then
    tail -n 40 /var/log/yt-dlp-webui.log 2>/dev/null || true
  fi
}

open_firewall() {
  port=$1
  if have ufw && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || say_warn "ufw 没能放开 ${port}"
    say_ok "ufw 已放开 ${port}/tcp"
  fi
  if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --add-port="${port}/tcp" --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    say_ok "firewalld 已放开 ${port}/tcp"
  fi
  if have iptables; then
    policy=$(iptables -S INPUT 2>/dev/null | awk 'NR==1 && $1=="-P" && $2=="INPUT" {print $3}')
    if [ "$policy" = "DROP" ] || [ "$policy" = "REJECT" ]; then
      if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT >/dev/null 2>&1 || true
        say_ok "iptables 已放开 ${port}/tcp"
      fi
    fi
  fi
}

collect_addrs() {
  ADDR_V4=
  ADDR_V4_PRIVATE=
  ADDR_V6=
  ips=
  if have hostname; then
    ips=$(hostname -I 2>/dev/null || true)
  fi
  if [ -z "$ips" ] && have ip; then
    ips=$(ip -o addr show 2>/dev/null | awk '{print $4}')
  fi
  for ip in $ips; do
    ip=${ip%%/*}
    if is_ipv4 "$ip"; then
      if is_private_ipv4 "$ip"; then
        [ -n "$ADDR_V4_PRIVATE" ] || ADDR_V4_PRIVATE=$ip
      else
        [ -n "$ADDR_V4" ] || ADDR_V4=$ip
      fi
    elif is_global_ipv6 "$ip"; then
      [ -n "$ADDR_V6" ] || ADDR_V6=$ip
    fi
  done
}

hash_password() {
  user=$1
  pass=$2
  if ! need_tool htpasswd; then
    ensure_tool htpasswd || die "装不上生成密码用的 htpasswd。没有登录不能把网页暴露出去。"
  fi
  line=$(htpasswd -nbB "$user" "$pass" 2>/dev/null || true)
  hash=$(printf '%s\n' "$line" | awk -F: 'NR==1 {print substr($0, index($0, ":")+1)}')
  case "$hash" in
    \$2a\$*|\$2b\$*|\$2y\$*) printf '%s\n' "$hash"; return 0 ;;
  esac
  die "密码哈希没生成。htpasswd 的输出是：${line:-空}"
}

read_saved_password() {
  [ -f /etc/yt-dlp-webui/install.txt ] || return 1
  sed -n 's/^password=//p' /etc/yt-dlp-webui/install.txt | head -n 1
}

write_install_note() {
  user=$1
  pass=$2
  port=$3
  umask 077
  {
    printf 'username=%s\n' "$user"
    printf 'password=%s\n' "$pass"
    printf 'port=%s\n' "$port"
  } > /etc/yt-dlp-webui/install.txt
  chmod 600 /etc/yt-dlp-webui/install.txt
  umask 022
}

install_cli() {
  dest=/usr/local/sbin/ytdlp-web
  mkdir -p /usr/local/sbin /usr/local/bin
  if [ -f "$0" ]; then
    cp "$0" "$dest"
    chmod 755 "$dest"
  fi
  link=$(shortcut_link_dir "$PATH")
  if [ -n "$link" ]; then
    ln -sfn "$dest" "$link/ytdlp-web"
  fi
}

fetch_quiet() {
  dest=$1
  shift
  for url in "$@"; do
    rm -f "$dest"
    if have curl; then
      curl -fsSL --connect-timeout 10 --max-time 25 -o "$dest" "$url" && [ -s "$dest" ] && return 0
    elif have wget; then
      wget -q -O "$dest" "$url" && [ -s "$dest" ] && return 0
    else
      return 1
    fi
  done
  rm -f "$dest"
  return 1
}

maybe_self_update() {
  [ "${YTD_UPDATED:-}" = 1 ] && return 0
  [ "${YTD_NO_UPDATE:-}" = 1 ] && return 0
  [ "${YTD_TEST:-}" = 1 ] && return 0
  tmp=/tmp/ytdlp-install.new
  fetch_quiet "$tmp" \
    "https://raw.githubusercontent.com/imthnio/vps-ytdlp/main/install.sh" \
    "https://cdn.jsdelivr.net/gh/imthnio/vps-ytdlp@main/install.sh" || true
  if ! remote_script_ok "$tmp"; then
    rm -f "$tmp"
    return 0
  fi
  remote=$(version_from_file "$tmp")
  if version_newer "$remote" "$VERSION"; then
    say_info "发现新版本 $remote，改用新脚本继续"
    cp "$tmp" /tmp/ytdlp-install.run
    chmod 755 /tmp/ytdlp-install.run
    rm -f "$tmp"
    YTD_UPDATED=1
    export YTD_UPDATED
    exec /bin/sh /tmp/ytdlp-install.run "$@"
  fi
  rm -f "$tmp"
}

print_status() {
  detect_machine
  printf '%s\n' "系统：$OS_PRETTY"
  printf '%s\n' "包管理：$PM    架构：$ARCH    系统库：$LIBC    启动方式：$INIT"
  printf '%s\n' "内存：${MEM_MB:-未知}MB    虚拟内存：${SWAP_MB:-0}MB    磁盘剩余：${DISK_MB}MB"
  if [ -x /usr/local/bin/yt-dlp ]; then
    printf '%s\n' "yt-dlp：$(/usr/local/bin/yt-dlp --version 2>/dev/null | head -n 1)"
  else
    printf '%s\n' "yt-dlp：还没装"
  fi
  if [ -x /usr/local/bin/yt-dlp-webui ]; then
    printf '%s\n' "网页程序：已安装"
  else
    printf '%s\n' "网页程序：还没装"
  fi
  port=$(config_get port 2>/dev/null || true)
  [ -n "$port" ] && printf '%s\n' "端口：$port"
  user=$(config_get username 2>/dev/null || true)
  [ -n "$user" ] && printf '%s\n' "用户名：$user"
  pass=$(read_saved_password 2>/dev/null || true)
  if [ -n "$pass" ]; then
    printf '%s\n' "密码：$pass"
  elif [ -f /etc/yt-dlp-webui/config.yml ]; then
    printf '%s\n' "密码：记录丢了。运行 ytdlp-web --reset-password 可以换一把新的。"
  fi
  case "$INIT" in
    systemd) systemctl --no-pager --full status yt-dlp-webui 2>/dev/null | head -n 12 || true ;;
    openrc) rc-service yt-dlp-webui status 2>/dev/null || true ;;
  esac
}

uninstall_all() {
  detect_machine
  printf '%s\n' "确定要卸掉网页下载器吗？"
  printf '%s\n' "已经下好的视频会留着，不会删。"
  printf '%s\n' "  1) 卸掉"
  printf '%s\n' "  2) 先不卸（推荐）"
  ask_menu UNINSTALL_OK 2 2
  if [ "$UNINSTALL_OK" != 1 ]; then
    say_ok "没有卸掉，网页还在。"
    return 0
  fi
  say_step "卸掉网页下载器"
  stop_service
  case "$INIT" in
    systemd)
      systemctl disable yt-dlp-webui >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/yt-dlp-webui.service
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-update del yt-dlp-webui default >/dev/null 2>&1 || true
      rm -f /etc/init.d/yt-dlp-webui
      ;;
    *)
      rm -f /etc/init.d/yt-dlp-webui
      ;;
  esac
  if [ -f /etc/yt-dlp-webui/swap.size ] && [ -f /yt-dlp-webui.swap ]; then
    swapoff /yt-dlp-webui.swap >/dev/null 2>&1 || true
    rm -f /yt-dlp-webui.swap
    fstab_remove_line /etc/fstab "/yt-dlp-webui.swap none swap sw 0 0"
  fi
  if [ -f /etc/yt-dlp-webui/ffmpeg-static ]; then
    rm -f /usr/local/bin/ffmpeg /usr/local/bin/ffprobe
  fi
  rm -f /usr/local/bin/yt-dlp /usr/local/bin/yt-dlp-one /usr/local/bin/qjs \
    /usr/local/bin/yt-dlp-webui /usr/local/sbin/yt-dlp-webui-run /usr/local/sbin/ytdlp-web \
    /usr/bin/ytdlp-web /etc/sysctl.d/99-yt-dlp-webui-overcommit.conf
  rm -rf /etc/yt-dlp-webui
  say_ok "程序已卸掉。下载过的视频还在 ${DATA}/downloads ，没有删。"
}

# 键盘不在脚本的输入上时，改回真正的键盘。
# 不能写进 ask_line：测试用管道喂答案时，这里去读 /dev/tty 会卡住。
prepare_stdin() {
  [ "${YTD_TEST:-}" = 1 ] && return 0
  if [ ! -t 0 ] && [ -r /dev/tty ] && (: < /dev/tty) 2>/dev/null; then
    exec < /dev/tty
  fi
}

ask_stop() {
  printf '\n' >&2
  die "没有读到你的选择，已停止，没有继续安装。请重新运行安装命令，在键盘上回答问题。"
}

# ask_line "说明" "默认值" 变量名。直接回车用默认值。只去掉两头空格。
ask_line() {
  _p=$1
  _d=$2
  _v=$3
  printf '%s\n' "$_p"
  if [ -n "$_d" ]; then
    printf '不懂就直接按回车，会用：%s\n' "$_d"
  fi
  printf '请输入：'
  if ! read -r _a; then
    ask_stop
  fi
  _a=$(printf '%s' "$_a" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  if [ -z "$_a" ]; then
    _a=$_d
  fi
  _a_esc=$(printf '%s' "$_a" | sed "s/'/'\\\\''/g")
  eval "$_v='$_a_esc'"
}

# 先把选项印出来，再调用。直接回车用默认数字。输错会再问。
ask_menu() {
  _v=$1
  _d=$2
  _max=$3
  while true; do
    printf '请输入数字后回车 [直接回车 = %s]：' "$_d"
    if ! read -r _a; then
      ask_stop
    fi
    got=$(menu_answer "$_a" "$_d" "$_max")
    if [ "$got" = bad ]; then
      printf '%s\n' "请输入 1 到 ${_max} 的数字。不懂就直接按回车。"
      continue
    fi
    eval "$_v='$got'"
    return 0
  done
}

ask_settings() {
  reset_pass=$1
  PASS_MODE=new
  say_step "先回答 6 个问题"
  printf '%s\n' "每一题都可以直接按回车。回车就是适合新手的选项。"

  saved_port=$(config_get port 2>/dev/null || true)
  [ -n "$saved_port" ] || saved_port=3033
  printf '\n%s\n' "第 1 题：网页端口"
  printf '%s\n' "Mac 打开网页时，地址是 http://小鸡IP:端口"
  printf '%s\n' "端口就是冒号后面那个数字。例如 3033。"
  while true; do
    ask_line "想用哪个端口？" "$saved_port" PORT_CHOSEN
    PORT_CHOSEN=$(normalize_port "$PORT_CHOSEN" 2>/dev/null || printf '%s' "$PORT_CHOSEN")
    why=$(port_text_problem "$PORT_CHOSEN")
    case "$why" in
      ok) ;;
      ssh)
        say_warn "22 是你登录这台鸡用的，不能给网页。直接回车就用 ${saved_port}。"
        continue
        ;;
      *)
        say_warn "请输入 1 到 65535 的数字。不懂就直接回车。"
        continue
        ;;
    esac
    if port_taken_by_other "$PORT_CHOSEN"; then
      say_warn "端口 ${PORT_CHOSEN} 已经有别的程序在用。请输入另一个数字，比如 8080。这一题不要直接回车。"
      saved_port=
      continue
    fi
    break
  done

  saved_user=$(config_get username 2>/dev/null || true)
  [ -n "$saved_user" ] || saved_user=admin
  printf '\n%s\n' "第 2 题：登录名字"
  printf '%s\n' "打开网页要先登录，这样别人不能拿你的鸡去下载。"
  printf '%s\n' "名字只用英文字母和数字。"
  while true; do
    ask_line "登录名字用什么？" "$saved_user" USER_CHOSEN
    case "$(user_text_problem "$USER_CHOSEN")" in
      ok) break ;;
      len) say_warn "名字太长了，请控制在 32 位以内。" ;;
      *) say_warn "名字里只能有英文字母和数字，例如 admin 或 xiaoming。" ;;
    esac
  done

  printf '\n%s\n' "第 3 题：登录密码"
  saved_pass=$(read_saved_password 2>/dev/null || true)
  saved_hash=$(config_get password_hash 2>/dev/null || true)
  if [ "$reset_pass" != 1 ] && [ -n "$saved_pass" ] && [ -n "$saved_hash" ]; then
    printf '%s\n' "这台鸡已经有密码了。"
    printf '%s\n' "  1) 继续用现在的密码（推荐）"
    printf '%s\n' "  2) 换一把新密码"
    ask_menu PASS_KEEP 1 2
    if [ "$PASS_KEEP" = 1 ]; then
      PASS_MODE=keep
      PASS_CHOSEN=$saved_pass
    fi
  fi
  if [ "$PASS_MODE" != keep ]; then
    printf '%s\n' "  1) 帮我随机生成一把（推荐，不容易被别人猜到）"
    printf '%s\n' "  2) 我自己设一个"
    ask_menu PASS_HOW 1 2
    if [ "$PASS_HOW" = 1 ]; then
      PASS_MODE=random
      PASS_CHOSEN=
    else
      PASS_MODE=custom
      printf '%s\n' "自己设密码时，屏幕上看得见字，这是正常的。设完请记到备忘录里。"
      while true; do
        ask_line "请输入密码。至少 6 位，字母和数字都可以" "" PASS_CHOSEN
        case "$(pass_text_problem "$PASS_CHOSEN")" in
          ok) ;;
          space)
            say_warn "密码里先不要加空格。"
            continue
            ;;
          *)
            say_warn "太短了。请至少 6 位，比如 abc123。"
            continue
            ;;
        esac
        ask_line "再输入一次，确认没有打错" "" PASS_AGAIN
        if [ "$PASS_CHOSEN" = "$PASS_AGAIN" ]; then
          break
        fi
        say_warn "两次不一样，请重新设。"
      done
    fi
  fi

  printf '\n%s\n' "第 4 题：一次下几个视频"
  if [ -n "$MEM_MB" ] && [ "$MEM_MB" -lt 768 ]; then
    printf '%s\n' "这台鸡大约 ${MEM_MB}MB 内存，比较小。"
    printf '%s\n' "一次只能下一个视频。两个一起下，鸡容易卡死。这一项已经帮你选好了。"
    QUEUE_CHOSEN=1
  else
    printf '%s\n' "  1) 一次下一个（更稳，推荐）"
    printf '%s\n' "  2) 一次下两个（更快，内存要够）"
    ask_menu QUEUE_CHOSEN 1 2
  fi

  printf '\n%s\n' "第 5 题：Mac 怎么打开这个网页"
  collect_addrs
  if [ -n "$ADDR_V4" ]; then
    printf '%s\n' "这台鸡有公网地址 ${ADDR_V4}，Mac 浏览器可以直接打开。"
    printf '%s\n' "  1) 浏览器直接打开（推荐）。需要的话我会放开这个端口。"
    printf '%s\n' "  2) 只用 SSH 转发，不把端口暴露到公网。"
    ask_menu OPEN_CHOSEN 1 2
  elif [ -n "$ADDR_V4_PRIVATE" ]; then
    printf '%s\n' "这台鸡的地址是 ${ADDR_V4_PRIVATE}，这是内网地址，Mac 不能直接打开。"
    printf '%s\n' "  1) 我已经在服务商面板做了端口映射，请放开小鸡上的端口。"
    printf '%s\n' "  2) 用 SSH 转发（推荐，不用懂端口映射）。"
    ask_menu OPEN_CHOSEN 2 2
  else
    printf '%s\n' "  1) 浏览器直接打开（推荐）"
    printf '%s\n' "  2) 只用 SSH 转发"
    ask_menu OPEN_CHOSEN 1 2
  fi

  printf '\n%s\n' "第 6 题：视频放在哪个文件夹"
  saved_dir=$(config_get download_path 2>/dev/null || true)
  [ -n "$saved_dir" ] || saved_dir="${DATA}/downloads"
  printf '%s\n' "下好的视频会放在这个文件夹。不懂路径就直接回车。"
  while true; do
    ask_line "视频文件夹" "$saved_dir" DIR_CHOSEN
    case "$(dir_text_problem "$DIR_CHOSEN")" in
      ok) break ;;
      relative) say_warn "请写从 / 开头的完整路径，例如 /root/youtube。或者直接回车。" ;;
      space) say_warn "路径里先不要加空格。" ;;
      system) say_warn "这个位置是系统用的，请换一个，例如 /root/youtube。" ;;
      *) say_warn "这个路径不能用。直接回车就用推荐的文件夹。" ;;
    esac
  done
}

show_plan() {
  printf '\n%s\n' "请核对，接下来会按这个装："
  printf '%s\n' "  端口：${PORT_CHOSEN}"
  printf '%s\n' "  登录名字：${USER_CHOSEN}"
  case "$PASS_MODE" in
    keep) printf '%s\n' "  密码：继续用现在的" ;;
    custom) printf '%s\n' "  密码：用你刚设的那把" ;;
    *) printf '%s\n' "  密码：随机生成，装完会显示出来" ;;
  esac
  if [ "$QUEUE_CHOSEN" = 2 ]; then
    printf '%s\n' "  下载：一次可以下两个"
  else
    printf '%s\n' "  下载：一次下一个"
  fi
  if [ "$OPEN_CHOSEN" = 2 ]; then
    printf '%s\n' "  Mac 打开方式：SSH 转发"
  else
    printf '%s\n' "  Mac 打开方式：浏览器直接打开"
  fi
  printf '%s\n' "  视频文件夹：${DIR_CHOSEN}"
  printf '\n%s\n' "  1) 开始安装（推荐）"
  printf '%s\n' "  2) 上面有选错的，重新答一遍"
}

print_how_to_open() {
  port=$1
  user=$2
  pass=$3
  open_mode=$4
  dir=$5
  collect_addrs
  printf '\n%s\n' "${C_GREEN}装好了。${C_NC}"
  printf '%s\n' "用户名：${user}"
  printf '%s\n' "密码：${pass}"
  printf '%s\n' "密码也记在 /etc/yt-dlp-webui/install.txt ，忘记了可以输入：ytdlp-web --status"
  if [ "$open_mode" = 2 ]; then
    printf '\n%s\n' "你选了 SSH 转发。在 Mac 终端执行（地址换成你平时登这台鸡用的）："
    printf '%s\n' "ssh -L ${port}:127.0.0.1:${port} root@你的鸡"
    printf '%s\n' "然后浏览器打开 http://127.0.0.1:${port}"
  elif [ -n "$ADDR_V4" ]; then
    printf '\n%s\n' "在 Mac 浏览器打开："
    printf '%s\n' "http://${ADDR_V4}:${port}"
  elif [ -n "$ADDR_V6" ] && [ -z "$ADDR_V4_PRIVATE" ]; then
    printf '\n%s\n' "在 Mac 浏览器打开："
    printf '%s\n' "http://[${ADDR_V6}]:${port}"
  fi
  if [ "$open_mode" != 2 ] && [ -n "$ADDR_V4_PRIVATE" ] && [ -z "$ADDR_V4" ]; then
    printf '\n%s\n' "这台小鸡的地址是 ${ADDR_V4_PRIVATE}，外面不能直接打开。"
    printf '%s\n' "请在服务商面板把公网端口转到这台鸡的 ${port}，再用公网地址打开。"
    printf '%s\n' "如果还没做映射，可以在 Mac 终端执行："
    printf '%s\n' "ssh -L ${port}:127.0.0.1:${port} root@你的鸡"
    printf '%s\n' "然后浏览器打开 http://127.0.0.1:${port}"
  fi
  printf '\n%s\n' "把 YouTube 链接贴进网页，视频会下到 ${dir} 。"
  printf '%s\n' "下完后在网页里可以把文件再下回 Mac。鸡的硬盘不大，下回 Mac 后把鸡上的文件删掉。"
  if [ "$QUEUE_CHOSEN" = 1 ]; then
    printf '%s\n' "按你的选择，视频会一个接一个下载。"
  fi
  printf '%s\n' "以后要改端口、密码或文件夹，再运行一次安装命令，或者输入 ytdlp-web 。每题直接回车就沿用现在的。"
  printf '%s\n' "查看：ytdlp-web --status    换密码：ytdlp-web --reset-password    卸载：ytdlp-web --uninstall"
}

do_install() {
  reset_pass=$1
  detect_machine
  say_step "这台鸡"
  say_info "系统：$OS_PRETTY"
  say_info "包管理：${PM}    架构：${ARCH}    系统库：${LIBC}    启动：${INIT}"
  say_info "内存：${MEM_MB:-未知}MB    已有虚拟内存：${SWAP_MB}MB    磁盘剩余：${DISK_MB}MB    CPU：${NCPU}"
  webui_asset "$ARCH" >/dev/null || die "这个网页程序没有 $ARCH 的版本，32 位系统装不了。"
  ytdlp_asset "$ARCH" "$LIBC" >/dev/null || die "没有适合 $ARCH / $LIBC 的 yt-dlp。"

  while true; do
    ask_settings "$reset_pass"
    show_plan
    ask_menu PLAN_OK 1 2
    [ "$PLAN_OK" = 1 ] && break
    printf '%s\n' "好，我们再答一遍。"
  done

  say_step "准备内存和软件源"
  prepare_workdir
  prepare_memory
  ensure_tool ca || say_warn "证书包没装上，后面下载可能会失败"
  ensure_tool curl || die "装不上 curl 或 wget，没法下载程序。"
  ensure_tool tar || die "装不上 tar。"
  ensure_tool flock || die "装不上 flock。小内存机器要用它把下载排成一个一个。"

  ensure_ffmpeg
  install_qjs
  install_ytdlp
  stop_service
  install_webui

  mkdir -p "$DATA/downloads" "$DATA/tmp" "$DATA/cache" "$DATA/home" "$DIR_CHOSEN" /etc/yt-dlp-webui /usr/local/sbin
  DL=$(downloader_for_choice "$QUEUE_CHOSEN")
  if [ "$DL" = /usr/local/bin/yt-dlp-one ]; then
    write_one_wrapper
    say_ok "按你的选择，视频会一个接一个下载"
  else
    rm -f /usr/local/bin/yt-dlp-one
    say_ok "按你的选择，可以同时下两个"
  fi

  user=$USER_CHOSEN
  if [ "$PASS_MODE" = keep ]; then
    pass=$PASS_CHOSEN
    hash=$(config_get password_hash 2>/dev/null || true)
    [ -n "$hash" ] || die "原来的密码记录坏了。请重新运行，并选择换一把新密码。"
    say_ok "沿用原来的登录密码"
  elif [ "$PASS_MODE" = custom ]; then
    pass=$PASS_CHOSEN
    hash=$(hash_password "$user" "$pass")
  else
    say_step "生成登录密码"
    pass=$(rand_hex 8) || die "随机密码没生成。"
    hash=$(hash_password "$user" "$pass")
  fi

  secret=$(env_get JWT_SECRET 2>/dev/null || true)
  if [ -z "$secret" ]; then
    secret=$(rand_hex 24) || die "登录密钥没生成。"
  fi
  gomem=$(gomem_for "${MEM_MB:-1024}")
  write_env_file "$secret" "$gomem"
  write_runner

  port=$PORT_CHOSEN
  q=$QUEUE_CHOSEN
  write_config /etc/yt-dlp-webui/config.yml "$port" "$user" "$hash" "$DL" "$JS_RUNTIME" "$q" "$DATA" "$DIR_CHOSEN"
  chmod 600 /etc/yt-dlp-webui/config.yml
  write_install_note "$user" "$pass" "$port"
  write_service
  install_cli
  if [ "$OPEN_CHOSEN" = 1 ]; then
    open_firewall "$port"
  else
    say_info "按你的选择，没有把端口放开到公网。"
  fi

  say_step "启动"
  start_service || true
  if ! health_ok "$port" && [ -n "$gomem" ]; then
    say_warn "带内存上限时网页没起来，去掉上限再试一次"
    write_env_file "$secret" ""
    start_service || true
  fi
  if ! health_ok "$port"; then
    show_fail_log
    die "网页没能在端口 $port 上打开。"
  fi
  say_ok "网页已在端口 ${port} 运行"
  rm -rf "$WORK"
  print_how_to_open "$port" "$user" "$pass" "$OPEN_CHOSEN" "$DIR_CHOSEN"
}

usage() {
  printf '%s\n' "用法："
  printf '%s\n' "  ytdlp-web                 安装或更新（会用大白话问几个问题，直接回车就是推荐项）"
  printf '%s\n' "  ytdlp-web --status        查看"
  printf '%s\n' "  ytdlp-web --reset-password  换一把登录密码"
  printf '%s\n' "  ytdlp-web --uninstall     卸掉程序，留下已经下好的视频"
}

main() {
  action=install
  for arg in "$@"; do
    case "$arg" in
      --status|-s) action=status ;;
      --uninstall) action=uninstall ;;
      --reset-password) action=reset ;;
      --help|-h) usage; exit 0 ;;
      *) die "不认识的参数：$arg" ;;
    esac
  done
  case "$(uname -s)" in
    Linux) ;;
    *) die "这个脚本要在 Linux 小鸡上运行。你现在是 $(uname -s)。" ;;
  esac
  if [ "$action" = status ]; then
    print_status
    exit 0
  fi
  if [ "$(id -u)" -ne 0 ]; then
    die "请用 root 运行。可以先输入：sudo -i"
  fi
  prepare_stdin
  maybe_self_update "$@"
  case "$action" in
    uninstall) uninstall_all ;;
    reset) do_install 1 ;;
    install) do_install 0 ;;
  esac
}

if [ "${YTD_TEST:-}" != 1 ]; then
  main "$@"
fi
