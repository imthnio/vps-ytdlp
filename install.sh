#!/bin/sh
#======================================================================
# yt-dlp 一键脚本：在 Mac 浏览器里贴视频链接，视频（或图片）自动存进 Mac
# 支持 YouTube、抖音、小红书、B站、TikTok、推特/X、Instagram，可以直接粘 App 里复制的整段分享文字
#----------------------------------------------------------------------
# 在 Linux VPS（小鸡）上装好一个小网页。Mac 浏览器打开它，贴链接、点开始，
# VPS 帮你从这些网站下好，马上让浏览器存进 Mac 的「下载」文件夹，
# 传完以后自动把 VPS 上的文件删掉。VPS 上不留视频。
#
# 64MB 内存也能装：不用 Docker，网页是一个只用系统自带 Perl 的小程序，
# 内存小的机器会先做一块硬盘上的虚拟内存，下载一个接一个来。
#
#   sh install.sh                    第一次：问 5 个问题再安装。装过：回车就是更新
#   sh install.sh --status           看看装得怎么样、密码是什么
#   sh install.sh --log              看最近的运行记录（排查问题用）
#   sh install.sh --reset-password   换一把登录密码
#   sh install.sh --uninstall        卸载
#
# 名词小词典（看不懂下面的注释时查这里）
#   VPS / 小鸡     你租的那台 Linux 服务器
#   网页服务       一直在 VPS 上跑的小网页程序（server.pl），Mac 浏览器打开的就是它
#   端口           网页地址里冒号后面的数字，例如 http://1.2.3.4:15346 里的 15346
#   yt-dlp         真正去各个网站下视频的程序。网站经常改，它每天自动更新
#   ffmpeg         把画面和声音合成一个文件的程序
#   QuickJS        很小的 JavaScript 程序。YouTube 现在要算一道 JavaScript 题才给视频
#   PO 令牌        YouTube 用来确认“你是真浏览器”的一串码。bgutil-pot 程序会自动算
#   WARP           Cloudflare 的免费线路。被网站拦时，换一个不被拦的出口 IP
#   wireproxy      不用改系统网络就能连 WARP 的小程序（容器里也能用）
#   cookies        浏览器里的登录记录。实在被拦时上传一份，yt-dlp 就像登录了你的小号
#   虚拟内存 swap  拿一块硬盘当内存用。慢，但小内存机器不会因为内存不够被杀掉
#   软件源         系统自带的装软件的地方（apt、apk、dnf 这些）
#   init/启动方式  开机时负责把程序拉起来的系统部件（systemd、OpenRC 等）
#   断点续传       网断了，浏览器从断的地方接着下（HTTP Range）
#======================================================================

VERSION=2.1.2
# ytdlp-onekey-begin

#----------------------------------------------------------------------
# 屏幕上的颜色和几种说话方式。终端不支持颜色时就不加颜色。
#----------------------------------------------------------------------
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
# 东西放在哪。测试时可以用环境变量换掉。
#----------------------------------------------------------------------
CONF_DIR=/etc/ytdlp-web
CONF_FILE=${YTD_CONFIG_FILE:-$CONF_DIR/web.conf}
NOTE_FILE=$CONF_DIR/install.txt
LIB_DIR=/usr/local/lib/ytdlp-web
SERVER_FILE=${YTD_SERVER_FILE:-$LIB_DIR/server.pl}
POT_PLUGIN_DIR=$LIB_DIR/pot-plugins
# 我们自己的 yt-dlp 小插件（小红书、B站、抖音、推特图片）放这里
PLUGIN_DIR=$LIB_DIR/plugins
WARP_DIR=$CONF_DIR/warp
RUNNER=/usr/local/sbin/ytdlp-web-run
CLI_FILE=/usr/local/sbin/ytdlp-web
LOG_FILE=/var/log/ytdlp-web.log
SWAP_FILE=/ytdlp-web.swap
# 旧版（1.x，用 yt-dlp-web-ui 的那种）放东西的地方。升级时读它的端口和密码，然后清掉。
OLD_CONF=${YTD_OLD_CONF:-/etc/yt-dlp-webui/config.yml}
OLD_NOTE=${YTD_OLD_NOTE:-/etc/yt-dlp-webui/install.txt}

#----------------------------------------------------------------------
# 同一时间只能跑一份：两份一起装，会抢软件源的锁、互相覆盖文件。
# 做法：mkdir 建一个锁目录（建目录这一步要么成功要么失败，不会两个人同时成功），
# 里面写上自己的进程号。别人来了看到目录在、进程还活着，就提示后退出。
# 进程已经不在了（比如上次被强行关掉），就当作残留，自动清掉。
# 退出、出错、按 Ctrl+C 都会删掉锁。只看不改的 --status、--log 不加锁。
#----------------------------------------------------------------------
lock_dir_default() {
  for d in /run /var/run /tmp; do
    if [ -d "$d" ] && [ -w "$d" ]; then
      printf '%s\n' "$d/ytdlp-web.lock"
      return 0
    fi
  done
  printf '%s\n' /tmp/ytdlp-web.lock
}
LOCK_DIR=${YTD_LOCK_DIR:-$(lock_dir_default)}
LOCK_HELD=0

pid_alive() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$1" 2>/dev/null && return 0
  # 没权限发信号时，看 /proc 里还有没有这个进程。
  [ -d "/proc/$1" ]
}

lock_owner() {
  sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null | tr -cd '0-9'
}

# 成功拿到锁返回 0；已经有一份在跑返回 1，并把它的进程号放在 LOCK_OTHER。
lock_try() {
  LOCK_OTHER=
  tries=0
  while [ "$tries" -lt 5 ]; do
    tries=$((tries + 1))
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" > "$LOCK_DIR/pid"
      LOCK_HELD=1
      return 0
    fi
    owner=$(lock_owner)
    # 自动更新时脚本会用 exec 换成新版本，进程号不变，锁本来就是自己的。
    if [ "$owner" = "$$" ]; then
      LOCK_HELD=1
      return 0
    fi
    if [ -z "$owner" ]; then
      # 别人刚建好目录、还没来得及写进程号。等一秒再看。
      sleep 1
      owner=$(lock_owner)
      if [ -z "$owner" ] && [ "$tries" -lt 3 ]; then
        continue
      fi
    fi
    if [ -n "$owner" ] && pid_alive "$owner"; then
      LOCK_OTHER=$owner
      return 1
    fi
    # 残留的锁：先改名再删。改名只有一个人能成功，免得两个人同时清理、同时拿到锁。
    stale="$LOCK_DIR.stale.$$"
    if mv "$LOCK_DIR" "$stale" 2>/dev/null; then
      if [ "$(sed -n '1p' "$stale/pid" 2>/dev/null | tr -cd '0-9')" = "$owner" ]; then
        rm -rf "$stale"
      else
        # 改名的瞬间别人已经换上了新锁，还给它。
        mv "$stale" "$LOCK_DIR" 2>/dev/null || rm -rf "$stale"
      fi
    fi
  done
  LOCK_OTHER=$(lock_owner)
  return 1
}

lock_release() {
  [ "$LOCK_HELD" = 1 ] || return 0
  if [ "$(lock_owner)" = "$$" ]; then
    rm -rf "$LOCK_DIR"
  fi
  LOCK_HELD=0
}

lock_or_quit() {
  if ! lock_try; then
    die "已经有一个安装在进行（进程号 ${LOCK_OTHER:-未知}），等它结束再运行。"
  fi
  set_quit_traps
}

# 安装脚本退出时（正常结束、出错、按 Ctrl+C）都要做的收尾：撤掉「正在升级」的牌子，放开锁。
quit_cleanup() {
  upgrade_flag_clear
  lock_release
}

set_quit_traps() {
  trap 'quit_cleanup' EXIT
  trap 'quit_cleanup; exit 129' HUP
  trap 'quit_cleanup; printf "\n"; exit 130' INT
  trap 'quit_cleanup; exit 143' TERM
}

#----------------------------------------------------------------------
# 升级时不打断正在下的视频。
#   做法：先在 $DATA/state/upgrading 挂一块「正在升级」的牌子（里面写安装脚本的进程号），
#   网页服务看到牌子就不再开始新的任务（排队的先等着，重启后自动接着下；新贴的链接照收），
#   脚本等「正在下载的」和「正在传给浏览器的」都结束了，才停掉网页服务、换新版本、再启动。
#   已经下好、还没传到 Mac 的文件记在硬盘上，重启以后照样在，浏览器会接着自动保存。
#   安装脚本中途退出时，牌子会被撤掉；就算没撤掉，网页服务发现那个进程号已经不在了，也会当它不存在。
#----------------------------------------------------------------------
UPGRADE_FLAG=

upgrade_data_dir() {
  d=$(config_get data 2>/dev/null || true)
  [ -n "$d" ] || d=${DATA:-/var/lib/ytdlp-web}
  printf '%s\n' "$d"
}

upgrade_flag_set() {
  dd=$(upgrade_data_dir)
  [ -d "$dd/state" ] || return 0
  UPGRADE_FLAG=$dd/state/upgrading
  printf '%s\n' "$$" > "$UPGRADE_FLAG" 2>/dev/null || UPGRADE_FLAG=
}

upgrade_flag_clear() {
  if [ -n "${UPGRADE_FLAG:-}" ]; then
    rm -f "$UPGRADE_FLAG"
    UPGRADE_FLAG=
  fi
}

# 网页服务在不在跑（看它自己记下的进程号）。
web_running() {
  dd=${1:-$(upgrade_data_dir)}
  [ -f "$dd/state/server.pid" ] || return 1
  pid=$(tr -cd '0-9' < "$dd/state/server.pid")
  pid_alive "$pid"
}

# 数一数网页服务手上的活。打印四个数：
#   正在下载的  排队的  正在传给浏览器的  刚下好、浏览器马上就会来拿的
# 「刚下好」指下好不到 FRESH_SECS 秒（默认 45 秒）、一个字节都还没传的：网页开着的话，
# 1～2 秒内浏览器就会来拿，等一下免得刚好在重启那一刻来拿、浏览器报「下载失败」。
# 下好很久都没人拿的（网页没开），不用等：文件在硬盘上，重启后照样在，打开网页会接着自动保存。
count_busy() {
  jd=${1:-$(upgrade_data_dir)/jobs}
  nr=0
  nq=0
  ns=0
  nf=0
  now=$(date +%s)
  for d in "$jd"/*; do
    [ -d "$d" ] || continue
    st=$(sed -n 's/^state=//p' "$d/status" 2>/dev/null | head -n 1)
    case "$st" in
      running) nr=$((nr + 1)) ;;
      queued|'') nq=$((nq + 1)) ;;
      done)
        da=$(sed -n 's/^done_at=//p' "$d/status" | head -n 1 | tr -cd '0-9')
        if [ -n "$da" ] && [ $((now - da)) -lt "${FRESH_SECS:-45}" ] && [ ! -s "$d/sent" ] &&
          [ -n "$(sed -n 's/^file=//p' "$d/status" | head -n 1)" ]; then
          nf=$((nf + 1))
        fi
        ;;
    esac
    for a in "$d"/active.*; do
      [ -e "$a" ] || continue
      pid_alive "${a##*.}" && ns=$((ns + 1))
    done
  done
  printf '%s %s %s %s\n' "$nr" "$nq" "$ns" "$nf"
}

# 正在下载的那几个，一行一个：标题（进度）
busy_lines() {
  jd=${1:-$(upgrade_data_dir)/jobs}
  for d in "$jd"/*; do
    [ -f "$d/status" ] || continue
    [ "$(sed -n 's/^state=//p' "$d/status" | head -n 1)" = running ] || continue
    t=$(sed -n 's/^title=//p' "$d/status" | head -n 1)
    [ -n "$t" ] || t=$(sed -n 's/^url=//p' "$d/meta" 2>/dev/null | head -n 1)
    p=$(sed -n 's/^pct=//p' "$d/status" | head -n 1)
    printf '    %s（%s%%）\n' "$(printf '%s' "$t" | cut -c1-60)" "${p:-0}"
  done
}

# 等网页服务手上的活干完。最多等 WAIT_MAX_SECS 秒（默认 30 分钟）。
# 不想等：FORCE_RESTART=1，或者等的时候按 Ctrl+C（只是不等了，安装会接着做完）。
wait_for_idle() {
  dd=$(upgrade_data_dir)
  [ -d "$dd/jobs" ] || return 0
  web_running "$dd" || return 0
  if [ "${FORCE_RESTART:-0}" = 1 ]; then
    say_warn "FORCE_RESTART=1：不等正在下载的视频，直接重启（正在下的会被打断，重启后点「再试一次」）。"
    return 0
  fi
  upgrade_flag_set
  # 网页服务每秒看一次牌子。等它看到，免得刚好又开始一个新任务。
  sleep "${WAIT_SETTLE_SECS:-2}"
  max=${WAIT_MAX_SECS:-1800}
  step=${WAIT_STEP_SECS:-5}
  waited=0
  shown=0
  SKIP_WAIT=0
  while :; do
    # shellcheck disable=SC2046
    set -- $(count_busy "$dd/jobs")
    nr=$1 nq=$2 ns=$3 nf=$4
    if [ "$nr" -eq 0 ] && [ "$ns" -eq 0 ] && [ "$nf" -eq 0 ]; then
      [ "$shown" = 1 ] && say_ok "都下完了，现在重启网页服务。"
      break
    fi
    if [ "$shown" = 0 ]; then
      shown=1
      trap 'SKIP_WAIT=1' INT
      if [ "$nr" -gt 0 ]; then
        say_step "有 ${nr} 个视频正在下载，等它们下完再重启……"
      elif [ "$ns" -gt 0 ]; then
        say_step "有 ${ns} 个文件正在传到 Mac，等传完再重启……"
      else
        say_step "有 ${nf} 个视频刚下好，等浏览器拿走再重启……"
      fi
      [ "$nq" -gt 0 ] && printf '%s\n' "另外 ${nq} 个排队的先等着，重启后会自动接着下。"
      printf '%s\n' "最多等 $((max / 60)) 分钟。不想等、马上重启（正在下的会被打断）：按 Ctrl+C。"
      printf '%s\n' "以后想不等直接升级：FORCE_RESTART=1 ytdlp-web"
    fi
    if [ "$SKIP_WAIT" = 1 ]; then
      printf '\n'
      say_warn "不等了，马上重启。被打断的视频，重启后在网页上点「再试一次」。"
      break
    fi
    if ! web_running "$dd"; then
      say_warn "网页服务自己停了，不用再等。"
      break
    fi
    if [ "$waited" -ge "$max" ]; then
      say_warn "等了 $((max / 60)) 分钟还没下完，先重启。被打断的视频，重启后在网页上点「再试一次」。"
      break
    fi
    if [ $((waited % 30)) -eq 0 ]; then
      printf '%s\n' "  已经等了 $((waited / 60)) 分 $((waited % 60)) 秒：正在下 ${nr} 个，正在传到 Mac ${ns} 个"
      busy_lines "$dd/jobs"
    fi
    sleep "$step" || true
    waited=$((waited + step))
  done
  if [ "$LOCK_HELD" = 1 ]; then set_quit_traps; else trap - INT; fi
  return 0
}

#----------------------------------------------------------------------
# 版本号比较。用来判断网上的脚本是不是更新。
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

# 网上下来的脚本要像样：第一行对、有版本号、有记号、语法没错，才肯用它。
remote_script_ok() {
  file=$1
  [ -s "$file" ] || return 1
  head -n 1 "$file" | grep -q '^#!/bin/sh' || return 1
  ver=$(version_from_file "$file")
  [ -n "$ver" ] || return 1
  grep -q 'ytdlp-onekey-begin' "$file" || return 1
  sh -n "$file" >/dev/null 2>&1
}

#----------------------------------------------------------------------
# 架构、系统库对应的下载文件名。测试会直接调用这些函数。
#----------------------------------------------------------------------
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

# PO 令牌程序只有 64 位 x86 和 ARM 的版本，而且要 glibc。
pot_asset() {
  case "$1:$2" in
    amd64:glibc) printf '%s\n' bgutil-pot-linux-x86_64 ;;
    arm64:glibc) printf '%s\n' bgutil-pot-linux-aarch64 ;;
    *) return 1 ;;
  esac
}

# 算 PO 令牌时大约要 70MB 内存。内存加虚拟内存不到 300MB 就不装，免得把小鸡拖死。
pot_wanted() {
  arch=$1
  libc=$2
  mem=$3
  swap=$4
  pot_asset "$arch" "$libc" >/dev/null || return 1
  case "$mem$swap" in ''|*[!0-9]*) return 1 ;; esac
  [ $((mem + swap)) -ge 300 ]
}

wgcf_asset() {
  ver=$1
  case "$2" in
    amd64) printf 'wgcf_%s_linux_amd64\n' "$ver" ;;
    arm64) printf 'wgcf_%s_linux_arm64\n' "$ver" ;;
    armv7) printf 'wgcf_%s_linux_armv7\n' "$ver" ;;
    armv6) printf 'wgcf_%s_linux_armv6\n' "$ver" ;;
    386) printf 'wgcf_%s_linux_386\n' "$ver" ;;
    *) return 1 ;;
  esac
}

wireproxy_asset() {
  case "$1" in
    amd64) printf '%s\n' wireproxy_linux_amd64.tar.gz ;;
    arm64) printf '%s\n' wireproxy_linux_arm64.tar.gz ;;
    armv7|armv6) printf '%s\n' wireproxy_linux_arm.tar.gz ;;
    386) printf '%s\n' wireproxy_linux_386.tar.gz ;;
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

#----------------------------------------------------------------------
# 内存小的机器怎么办。
# 目标是凑够大约 768MB 可用内存，yt-dlp 解一个视频才不会被杀掉。
# 硬盘要留下 160MB 给程序本身。算出来的大小按 64MB 对齐。
#----------------------------------------------------------------------
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

# /var 在内存盘上时，数据改放到根目录，免得视频把内存盘写满。
data_dir_for() {
  case "$1" in
    tmpfs|devtmpfs) printf '%s\n' /ytdlp-web-data ;;
    *) printf '%s\n' /var/lib/ytdlp-web ;;
  esac
}

# 64MB 小鸡的 /tmp 经常是一块很小的内存盘，40MB 的 yt-dlp 放不进去。
workdir_for() {
  kind=$1
  free=$2
  case "$free" in
    ''|*[!0-9]*) free=0 ;;
  esac
  case "$kind" in
    tmpfs|devtmpfs) printf '%s\n' /ytdlp-web-work ;;
    *)
      if [ "$free" -lt 120 ]; then
        printf '%s\n' /ytdlp-web-work
      else
        printf '%s\n' /tmp/ytdlp-web-work
      fi
      ;;
  esac
}

#----------------------------------------------------------------------
# 认系统：看 /etc/os-release 里的名字，决定用哪个软件源命令。
#----------------------------------------------------------------------
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

# 同一个工具，在不同系统的软件源里叫不同的名字。
pkg_name() {
  case "$1:$2" in
    *:curl) printf '%s\n' curl ;;
    *:ca) printf '%s\n' ca-certificates ;;
    *:tar) printf '%s\n' tar ;;
    apt:xz) printf '%s\n' xz-utils ;;
    *:xz) printf '%s\n' xz ;;
    *:unzip) printf '%s\n' unzip ;;
    *:ffmpeg) printf '%s\n' ffmpeg ;;
    pacman:python3) printf '%s\n' python ;;
    *:python3) printf '%s\n' python3 ;;
    apt:perl) printf '%s\n' perl-base ;;
    opkg:perl) printf '%s\n' 'perl perlbase-essential perlbase-io perlbase-posix perlbase-socket perlbase-file perlbase-fcntl perlbase-errno perlbase-select perlbase-symbol perlbase-selectsaver' ;;
    *:perl) printf '%s\n' perl ;;
    *) return 1 ;;
  esac
}

#----------------------------------------------------------------------
# IP 地址判断：公网、内网、IPv6。决定告诉你用哪个地址打开网页。
#----------------------------------------------------------------------
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

#----------------------------------------------------------------------
# 配置文件：一行一个 key=value。网页服务和这个脚本都读它。
#----------------------------------------------------------------------
config_get() {
  key=$1
  file=${2:-$CONF_FILE}
  [ -f "$file" ] || return 1
  val=$(sed -n "s/^${key}=//p" "$file" | head -n 1)
  [ -n "$val" ] || return 1
  printf '%s\n' "$val"
}

# 旧版配置是 YAML，样子是“  port: 3033”。
old_config_get() {
  key=$1
  file=${2:-$OLD_CONF}
  [ -f "$file" ] || return 1
  val=$(sed -n "s/^  ${key}: //p" "$file" | head -n 1 | sed 's/^"//; s/"$//')
  [ -n "$val" ] || return 1
  printf '%s\n' "$val"
}

# 参数依次是：文件 端口 监听地址 名字 密码哈希 数据目录 yt-dlp JS运行时 ffmpeg
#            PO令牌程序 WARP配置 WARP端口 打开方式 是否要WARP
write_config() {
  file=$1
  [ -n "$file" ] && [ -n "$2" ] && [ -n "$4" ] && [ -n "$5" ] || return 1
  {
    printf '%s\n' '# ytdlp-web 的设置。install.sh 写的，网页服务读它。改完要重启网页服务。'
    printf 'port=%s\n' "$2"
    printf 'listen=%s\n' "$3"
    printf 'user=%s\n' "$4"
    printf 'pass_hash=%s\n' "$5"
    printf 'data=%s\n' "$6"
    printf 'ytdlp=%s\n' "$7"
    printf 'js=%s\n' "$8"
    printf 'ffmpeg=%s\n' "$9"
    shift 9
    printf 'pot=%s\n' "$1"
    if [ -n "$1" ]; then
      printf 'pot_plugins=%s\n' "$POT_PLUGIN_DIR"
    else
      printf 'pot_plugins=\n'
    fi
    printf 'warp_conf=%s\n' "$2"
    if [ -n "$2" ]; then
      printf 'wireproxy=%s\n' /usr/local/bin/wireproxy
    else
      printf 'wireproxy=\n'
    fi
    printf 'warp_port=%s\n' "${3:-40000}"
    printf 'open_mode=%s\n' "${4:-1}"
    printf 'warp=%s\n' "${5:-0}"
    printf 'cookies=%s\n' "$CONF_DIR/cookies.txt"
    printf 'plugins=%s\n' "$PLUGIN_DIR"
    printf 'keep_hours=%s\n' 6
    printf 'grace=%s\n' 120
    printf 'log=%s\n' "$LOG_FILE"
  } > "$file"
}

#----------------------------------------------------------------------
# 检查你输入的东西对不对。只判断，不读键盘。
#----------------------------------------------------------------------
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
  if [ "${#p}" -gt 5 ] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
    printf '%s\n' range
    return 0
  fi
  if [ "$p" -eq 22 ]; then
    printf '%s\n' ssh
    return 0
  fi
  printf '%s\n' ok
}

# 只有已经装过、并且端口合法时，回车才沿用。第一次安装没有默认端口。
port_prompt_default() {
  saved=$(normalize_port "$1" 2>/dev/null) || return 1
  [ "$(port_text_problem "$saved")" = ok ] || return 1
  printf '%s\n' "$saved"
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

listen_for_open() {
  if [ "$1" = 2 ]; then
    printf '%s\n' 127.0.0.1
  else
    printf '%s\n' 0.0.0.0
  fi
}

#----------------------------------------------------------------------
# 往 /etc/fstab 这类文件里加一行、删一行。上一行没换行时也不会粘在一起。
#----------------------------------------------------------------------
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

# ytdlp-web 这个命令放在哪个目录，才能直接敲名字就用。
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
# 装过没有：配置、密码哈希和网页程序都在，才算装过。坏掉的记录会重新问。
#----------------------------------------------------------------------
install_ready() {
  [ -f "$SERVER_FILE" ] || return 1
  port=$(config_get port) || return 1
  [ "$(port_text_problem "$port")" = ok ] || return 1
  user=$(config_get user) || return 1
  [ "$(user_text_problem "$user")" = ok ] || return 1
  hash=$(config_get pass_hash) || return 1
  case "$hash" in
    \$*\$*) return 0 ;;
  esac
  return 1
}

old_install_present() {
  [ -f "$OLD_CONF" ] || [ -x /usr/local/bin/yt-dlp-webui ]
}

read_saved_password() {
  f=${1:-$NOTE_FILE}
  [ -f "$f" ] || return 1
  pw=$(sed -n 's/^password=//p' "$f" | head -n 1)
  [ -n "$pw" ] || return 1
  printf '%s\n' "$pw"
}

# 更新时读回原来的端口、名字、打开方式和 WARP 选择。
load_saved_choices() {
  PORT_CHOSEN=$(config_get port) || return 1
  [ "$(port_text_problem "$PORT_CHOSEN")" = ok ] || return 1
  USER_CHOSEN=$(config_get user) || return 1
  [ "$(user_text_problem "$USER_CHOSEN")" = ok ] || return 1
  PASS_MODE=keep
  PASS_CHOSEN=$(read_saved_password 2>/dev/null || true)
  OPEN_CHOSEN=$(config_get open_mode 2>/dev/null || true)
  [ "$OPEN_CHOSEN" = 2 ] || OPEN_CHOSEN=1
  WARP_CHOSEN=$(config_get warp 2>/dev/null || true)
  [ "$WARP_CHOSEN" = 1 ] || WARP_CHOSEN=0
  return 0
}

# 从旧版（1.x）读端口、名字和密码原文。密码原文没有时，装的时候重新随机一把。
load_old_choices() {
  PORT_CHOSEN=$(old_config_get port 2>/dev/null) || return 1
  PORT_CHOSEN=$(normalize_port "$PORT_CHOSEN" 2>/dev/null) || return 1
  [ "$(port_text_problem "$PORT_CHOSEN")" = ok ] || return 1
  USER_CHOSEN=$(old_config_get username 2>/dev/null || true)
  [ "$(user_text_problem "$USER_CHOSEN")" = ok ] || USER_CHOSEN="admin"
  PASS_CHOSEN=$(read_saved_password "$OLD_NOTE" 2>/dev/null || true)
  if [ -n "$PASS_CHOSEN" ] && [ "$(pass_text_problem "$PASS_CHOSEN")" = ok ]; then
    PASS_MODE=custom
  else
    PASS_MODE=random
    PASS_CHOSEN=
  fi
  OPEN_CHOSEN=1
  WARP_CHOSEN=1
  return 0
}

#======================================================================
# 下面开始碰这台机器。
#======================================================================

have() { command -v "$1" >/dev/null 2>&1; }

#----------------------------------------------------------------------
# 看内存、硬盘。容器里的内存上限写在 cgroup 里，比 /proc/meminfo 更准。
#----------------------------------------------------------------------
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
  got=$(df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
  # 有些容器里 df 找不到挂载点，改问 stat。
  if [ -z "$got" ] && have stat; then
    got=$(stat -f -c '%a %S' "$1" 2>/dev/null | awk '{print int($1 * $2 / 1048576)}')
  fi
  printf '%s\n' "${got:-0}"
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

#----------------------------------------------------------------------
# 认出这是什么系统、用什么装软件、什么架构、什么启动方式。
#----------------------------------------------------------------------
load_os() {
  OS_ID=unknown
  OS_VER=
  OS_LIKE=
  OS_PRETTY=Linux
  if [ -f /etc/os-release ]; then
    # 用函数里的 local，避免发行版文件里的变量漏到外面。
    # shellcheck disable=SC2039,SC3043
    local ID VERSION_ID ID_LIKE PRETTY_NAME
    ID=
    VERSION_ID=
    ID_LIKE=
    PRETTY_NAME=
    # shellcheck disable=SC1091
    . /etc/os-release
    [ -n "$ID" ] && OS_ID=$ID
    # shellcheck disable=SC2034
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

# 只认“真的在跑”的启动方式。装了 OpenRC 却没用它开机（很多容器这样），就当普通 SysV。
detect_init() {
  if [ -d /run/systemd/system ] && have systemctl; then
    INIT=systemd
    return 0
  fi
  if [ -d /run/openrc ] && have rc-service; then
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
  # 测试时可以假装成小内存机器。
  if [ -n "${YTD_MEM_MB:-}" ]; then
    MEM_MB=$YTD_MEM_MB
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
  saved_data=$(config_get data 2>/dev/null || true)
  case "$saved_data" in
    /var/lib/ytdlp-web|/ytdlp-web-data) DATA=$saved_data ;;
  esac
}

#----------------------------------------------------------------------
# 缺什么装什么。先看有没有，没有才用系统软件源装。
#----------------------------------------------------------------------
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
    python3) have python3 ;;
    perl) have perl && perl -MIO::Socket::INET -MIO::Select -MPOSIX -MFcntl -MFile::Path -e 1 >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# apt 的锁被别的程序占着时（比如系统在自动更新 unattended-upgrades），先等它，最多 3 分钟。
# 看 /proc 里有没有 apt、dpkg 这类进程在跑。
apt_busy_pid() {
  procdir=${YTD_PROC_DIR:-/proc}
  for f in "$procdir"/[0-9]*/comm; do
    [ -r "$f" ] || continue
    pid=${f%/comm}
    pid=${pid##*/}
    [ "$pid" = "$$" ] && continue
    case "$(cat "$f" 2>/dev/null)" in
      apt|apt-get|aptitude|dpkg)
        printf '%s\n' "$pid"
        return 0
        ;;
      unattended-upgr*)
        # Ubuntu 上一直挂着一个 unattended-upgrade-shutdown 等关机信号，它不占锁，不用等它。
        if ! tr '\0' ' ' < "${f%/comm}/cmdline" 2>/dev/null | grep -q 'shutdown'; then
          printf '%s\n' "$pid"
          return 0
        fi
        ;;
    esac
  done
  return 1
}

wait_apt_free() {
  limit=${YTD_APT_WAIT:-180}
  step=${YTD_APT_STEP:-3}
  waited=0
  told=0
  while busy=$(apt_busy_pid); do
    if [ "$waited" -ge "$limit" ]; then
      say_warn "等了 ${limit} 秒，系统的软件更新（进程号 ${busy}）还没结束。先试着装，装不上会换别的办法。"
      return 1
    fi
    if [ "$told" = 0 ]; then
      say_info "系统正在自己安装或更新软件（进程号 ${busy}），先等它结束，最多等 $((limit / 60)) 分钟…"
      told=1
    fi
    sleep "$step"
    waited=$((waited + step))
  done
  [ "$told" = 1 ] && say_ok "系统的软件更新结束了，继续"
  return 0
}

pm_update() {
  [ "${PM_UPDATED:-}" = 1 ] && return 0
  say_info "正在更新软件源（$PM）…"
  case "$PM" in
    apt)
      wait_apt_free || true
      DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -qq \
        || DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update
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

# 包名有时是好几个（OpenWrt 的 perl），所以这里不加引号，让它拆开。
pm_install_body() {
  pkg=$1
  # shellcheck disable=SC2086
  case "$PM" in
    apt)
      wait_apt_free || true
      # DPkg::Lock::Timeout：新一点的 apt 自己也会等锁，再多一道保险。老 apt 不认识这个设置，会忽略。
      DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends $pkg
      rm -f /var/cache/apt/archives/*.deb 2>/dev/null || true
      ;;
    apk) apk add --no-cache $pkg ;;
    dnf) dnf install -y $pkg ;;
    yum) yum install -y $pkg ;;
    pacman) pacman -S --noconfirm --needed $pkg ;;
    zypper) zypper --non-interactive install --no-recommends $pkg ;;
    opkg) opkg install $pkg ;;
    xbps) xbps-install -y $pkg ;;
    *) return 1 ;;
  esac
}

pm_install_one() {
  pkg=$1
  [ -n "$pkg" ] || return 1
  [ "$PM" = none ] && return 1
  pm_update || return 1
  say_info "安装 $pkg"
  # 64MB 的鸡有时会在装到一半时被系统杀掉。清一下缓存再试一次。
  if ! pm_install_body "$pkg"; then
    sync
    drop_page_cache
    pm_install_body "$pkg" || return 1
  fi
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

# 256MB 及以下不跑 40MB 的 yt-dlp 自解压程序，那个一启动就会把小鸡打死。
low_mem() {
  [ -n "${MEM_MB:-}" ] && [ "$MEM_MB" -le 256 ]
}

#----------------------------------------------------------------------
# 虚拟内存（swap）：内存不到 768MB 时，拿一块硬盘当内存用。
#----------------------------------------------------------------------
# 先用一小块试。容器经常禁止 swapon，没必要先写几百 MB 再失败。
swap_can_enable() {
  probe=/ytdlp-web.swap.probe
  swapoff "$probe" >/dev/null 2>&1 || true
  rm -f "$probe"
  write_swap_file "$probe" 8 || {
    rm -f "$probe"
    return 1
  }
  if mkswap "$probe" >/dev/null 2>&1 && swapon "$probe" >/dev/null 2>&1; then
    swapoff "$probe" >/dev/null 2>&1 || true
    rm -f "$probe"
    return 0
  fi
  swapoff "$probe" >/dev/null 2>&1 || true
  rm -f "$probe"
  return 1
}

# 不用 seek。空洞文件 swapon 会失败。busybox 的 dd 也没有 oflag。
write_swap_file() {
  path=$1
  mb=$2
  case "$mb" in
    ''|*[!0-9]*) return 1 ;;
  esac
  rm -f "$path"
  if ! { : > "$path"; } 2>/dev/null; then
    return 1
  fi
  left=$mb
  while [ "$left" -gt 0 ]; do
    chunk=8
    if [ "$left" -lt "$chunk" ]; then
      chunk=$left
    fi
    # 括号包住重定向。失败时 busybox 自己会喊 can't create，2>/dev/null 盖不住那一声。
    if ! { dd if=/dev/zero bs=1048576 count="$chunk" >>"$path"; } 2>/dev/null; then
      return 1
    fi
    left=$((left - chunk))
    sync
    drop_page_cache
  done
  return 0
}

prepare_memory() {
  if [ -n "$MEM_MB" ] && [ "$MEM_MB" -le 512 ]; then
    oc=$(tr -d ' \r\n' < /proc/sys/vm/overcommit_memory 2>/dev/null || true)
    if [ "$oc" != 1 ]; then
      # 很多容器的 /proc/sys 是只读的。[ -w ] 仍会说能写，直接重定向还会把报错打到屏幕上。
      if sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1 \
        || { printf '1\n' > /proc/sys/vm/overcommit_memory; } 2>/dev/null; then
        mkdir -p /etc/sysctl.d 2>/dev/null || true
        { printf 'vm.overcommit_memory=1\n' > /etc/sysctl.d/99-ytdlp-web-overcommit.conf; } 2>/dev/null || true
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
  if ! swap_can_enable; then
    say_warn "这台机器不允许打开虚拟内存（容器里很常见）。安装会继续，下载时会尽量省内存。"
    return 0
  fi
  if [ -f "$SWAP_FILE" ]; then
    swapoff "$SWAP_FILE" >/dev/null 2>&1 || true
    rm -f "$SWAP_FILE"
  fi
  say_info "内存大约 ${MEM_MB:-很少}MB。正在做 ${plan}MB 虚拟内存，下载视频时用得上…"
  # 一次写完几百 MB，64MB 的鸡会把内存缓存撑满，终端直接断开。改成一小段一小段写。
  if ! write_swap_file "$SWAP_FILE" "$plan"; then
    rm -f "$SWAP_FILE"
    say_warn "虚拟内存文件没写成，继续安装"
    return 0
  fi
  chmod 600 "$SWAP_FILE" 2>/dev/null || true
  if mkswap "$SWAP_FILE" >/dev/null 2>&1 && swapon "$SWAP_FILE" >/dev/null 2>&1; then
    fstab_append_line /etc/fstab "$SWAP_FILE none swap sw 0 0"
    mkdir -p "$CONF_DIR"
    printf '%s\n' "$plan" > "$CONF_DIR/swap.size"
    SWAP_MB=$((SWAP_MB + plan))
    DISK_MB=$(disk_free_mb /)
    say_ok "虚拟内存已打开（${plan}MB），重启后也会自动挂上"
  else
    rm -f "$SWAP_FILE"
    say_warn "这台机器不允许打开虚拟内存。安装会继续，下载时会尽量省内存。"
  fi
}

#----------------------------------------------------------------------
# 下载文件。GitHub 打不开时换镜像。小内存机器限速，免得页缓存把内存撑爆。
#----------------------------------------------------------------------
fetch_first() {
  dest=$1
  shift
  rate=
  if low_mem; then
    rate=1M
  fi
  for url in "$@"; do
    rm -f "$dest"
    say_info "下载 $url"
    ok=0
    if have curl; then
      if [ -n "$rate" ]; then
        curl -fL --retry 2 --connect-timeout 20 --max-time 900 --limit-rate "$rate" -o "$dest" "$url" && [ -s "$dest" ] && ok=1
      elif curl -fL --retry 2 --connect-timeout 20 --max-time 600 -o "$dest" "$url" && [ -s "$dest" ]; then
        ok=1
      fi
    elif have wget; then
      # BusyBox 自带的 wget 不认 --limit-rate，只有完整版 wget 才限速。
      if [ -n "$rate" ] && wget --help 2>&1 | grep -q -- '--limit-rate'; then
        wget -O "$dest" --limit-rate="$rate" "$url" && [ -s "$dest" ] && ok=1
      elif wget -O "$dest" "$url" && [ -s "$dest" ]; then
        ok=1
      fi
    else
      return 1
    fi
    if [ "$ok" = 1 ]; then
      if low_mem; then
        sync
        drop_page_cache
      fi
      return 0
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
is_gzip() { case "$(file_magic "$1")" in 1f8b*) return 0 ;; esac; return 1; }

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

prepare_workdir() {
  WORK=$(workdir_for "$(fstype_of /tmp)" "$(disk_free_mb /tmp)")
  rm -rf "$WORK"
  mkdir -p "$WORK/tmp" "$WORK/home" "$WORK/cache"
  # /tmp 在小内存鸡上经常是内存盘。下载和解压都改到硬盘，避免把内存撑爆。
  TMPDIR=$WORK/tmp
  HOME=$WORK/home
  XDG_CACHE_HOME=$WORK/cache
  TMP=$TMPDIR
  TEMP=$TMPDIR
  export TMPDIR HOME XDG_CACHE_HOME TMP TEMP
}

# 解压 zip：有 unzip 用 unzip，没有就试 busybox。
unzip_to() {
  zipf=$1
  dir=$2
  mkdir -p "$dir"
  if have unzip; then
    unzip -o -q "$zipf" -d "$dir" && return 0
  fi
  if have busybox && busybox unzip -o -q "$zipf" -d "$dir" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

#----------------------------------------------------------------------
# ffmpeg：合并画面和声音要用。先用软件源的，不行再下静态版本。
#----------------------------------------------------------------------
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
  # 有的系统只有 busybox 的 unxz，没有 xz 这个命令。
  if have xz; then
    xz -dc "$tmp" | tar -xf - -C "$dir" || true
  elif have unxz; then
    unxz -c "$tmp" | tar -xf - -C "$dir" || true
  else
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
  # 先拷成新文件再改名替换：正在下载的任务还在用旧的 ffmpeg 也不怕（直接覆盖会报「文件忙」）。
  place_elf "$ff" /usr/local/bin/ffmpeg || { rm -rf "$dir"; return 1; }
  place_elf "$fp" /usr/local/bin/ffprobe || { rm -rf "$dir"; return 1; }
  mkdir -p "$CONF_DIR"
  printf '%s\n' static > "$CONF_DIR/ffmpeg-static"
  rm -rf "$dir"
  need_tool ffmpeg
}

install_apk_ffmpeg_onebyone() {
  [ "$PM" = apk ] || return 1
  pm_update || return 1
  names=$(apk add --simulate --no-cache ffmpeg 2>/dev/null | sed -n 's/.*Installing \([^ ]*\) (.*/\1/p')
  [ -n "$names" ] || return 1
  say_info "内存大约 ${MEM_MB}MB。ffmpeg 的软件包一个一个装，避免把小鸡撑死"
  for name in $names; do
    if apk info -e "$name" >/dev/null 2>&1; then
      continue
    fi
    if ! apk add --no-cache "$name" >/dev/null 2>&1; then
      sync
      drop_page_cache
      apk add --no-cache "$name" >/dev/null 2>&1 || return 1
    fi
    sync
    drop_page_cache
  done
  need_tool ffmpeg
}

ensure_ffmpeg() {
  if need_tool ffmpeg; then
    say_ok "ffmpeg 已经有了"
    return 0
  fi
  say_step "安装 ffmpeg（合并视频和音频要用）"
  # 一次装一百个包，64MB 的鸡会被杀掉。Alpine 上改成一个一个装。
  if low_mem && [ "$PM" = apk ]; then
    if install_apk_ffmpeg_onebyone; then
      say_ok "ffmpeg 已从系统软件源装上"
      return 0
    fi
    say_warn "内存大约 ${MEM_MB}MB，ffmpeg 没装完。高画质合并会失败。"
    return 0
  fi
  if ensure_tool ffmpeg; then
    say_ok "ffmpeg 已从系统软件源装上"
    return 0
  fi
  # 40MB 的静态包在 128MB 及以下会把后面的安装一起打死。
  if [ -n "${MEM_MB:-}" ] && [ "$MEM_MB" -le 128 ]; then
    say_warn "内存大约 ${MEM_MB}MB，软件源里的 ffmpeg 没装上。高画质合并会失败。"
    return 0
  fi
  say_info "软件源里的 ffmpeg 没装上，改下静态版本"
  if install_static_ffmpeg; then
    say_ok "已装上静态 ffmpeg"
    return 0
  fi
  say_warn "ffmpeg 没装上。画面和声音分开的视频（YouTube 高画质、推特等）合并不了，会下载失败。"
  return 0
}

#----------------------------------------------------------------------
# QuickJS：YouTube 现在要算一道 JavaScript 题。这个程序只有 2MB，64MB 的鸡跑得动。
#----------------------------------------------------------------------
place_elf() {
  src=$1
  dest=$2
  is_elf "$src" || return 1
  mkdir -p "$(dirname "$dest")"
  # 先写到旁边的新文件，确认拷完再替换。失败时原来的程序还在。
  rm -f "$dest.new"
  cp "$src" "$dest.new" || return 1
  chmod 755 "$dest.new" || return 1
  mv "$dest.new" "$dest"
}

qjs_eval_ok() {
  [ -x "$1" ] || return 1
  "$1" -e 'print(1)' >/dev/null 2>&1
}

# 下载下来一般是 644。一个执行位都没有时，root 也跑不了。
# 下载目录还经常挂 noexec。先拷到可以执行的目录，chmod 之后再试。
place_and_test_qjs() {
  src=$1
  errf=$2
  for dest in /usr/local/bin/qjs /root/qjs; do
    mkdir -p "$(dirname "$dest")" 2>/dev/null || true
    trial=$dest.new
    rm -f "$trial"
    cp "$src" "$trial" 2>/dev/null || continue
    chmod 755 "$trial" 2>/dev/null || true
    if qjs_eval_ok "$trial"; then
      mv "$trial" "$dest" || { rm -f "$trial"; continue; }
      chmod 755 "$dest" 2>/dev/null || true
      printf '%s\n' "$dest"
      return 0
    fi
    "$trial" -e 'print(1)' >"$errf" 2>&1 || true
    rm -f "$trial"
  done
  return 1
}

try_distro_js() {
  case "$PM" in
    apk|apt|dnf|yum|pacman|zypper|opkg|xbps)
      pm_install_one quickjs >/dev/null 2>&1 || true
      ;;
  esac
  for bin in /usr/bin/qjs /usr/local/bin/qjs /usr/bin/quickjs; do
    if qjs_eval_ok "$bin"; then
      JS_RUNTIME=$(js_runtime_value quickjs "$bin")
      return 0
    fi
  done
  if ! low_mem; then
    case "$PM" in
      apk|apt|dnf|yum|pacman|zypper)
        pm_install_one nodejs >/dev/null 2>&1 || true
        ;;
    esac
    if command -v node >/dev/null 2>&1 && node -e 'console.log(1)' >/dev/null 2>&1; then
      JS_RUNTIME=$(js_runtime_value node "$(command -v node)")
      return 0
    fi
  fi
  return 1
}

install_qjs() {
  say_step "安装 QuickJS（YouTube 现在要它来算一道 JavaScript 题）"
  # 第一次装过就能用就跳过。更新时要换成最新的，旧的先留着，新的跑起来再替换。
  if [ "${UPDATE_MODE:-}" != 1 ] && qjs_eval_ok /usr/local/bin/qjs; then
    JS_RUNTIME=$(js_runtime_value quickjs /usr/local/bin/qjs)
    say_ok "QuickJS 已经能用，跳过下载"
    return 0
  fi
  asset=$(qjs_asset "$ARCH") || die "这个架构（$ARCH）没有 QuickJS，YouTube 下不了。"
  tag=$(latest_tag quickjs-ng/quickjs)
  [ -n "$tag" ] || tag=v0.17.0
  tmp=$WORK/qjs.new
  errf=$WORK/qjs.err
  : > "$errf"
  # shellcheck disable=SC2046
  if ! fetch_first "$tmp" $(github_urls "quickjs-ng/quickjs/releases/download/$tag/$asset"); then
    if [ "$tag" != v0.17.0 ]; then
      # shellcheck disable=SC2046
      fetch_first "$tmp" $(github_urls "quickjs-ng/quickjs/releases/download/v0.17.0/$asset") || true
    fi
  fi
  if ! is_elf "$tmp"; then
    rm -f "$tmp"
    if qjs_eval_ok /usr/local/bin/qjs; then
      JS_RUNTIME=$(js_runtime_value quickjs /usr/local/bin/qjs)
      say_warn "新的 QuickJS 没下下来，继续用现在的"
      return 0
    fi
    if try_distro_js; then
      say_ok "QuickJS 已从系统软件源装上"
      return 0
    fi
    die "QuickJS 下载下来不是程序。请检查这台鸡能不能打开 GitHub。"
  fi
  placed=$(place_and_test_qjs "$tmp" "$errf" || true)
  rm -f "$tmp"
  if [ -n "$placed" ]; then
    if [ "$placed" != /usr/local/bin/qjs ] && place_elf "$placed" /usr/local/bin/qjs 2>/dev/null; then
      if qjs_eval_ok /usr/local/bin/qjs; then
        placed=/usr/local/bin/qjs
      fi
    fi
    JS_RUNTIME=$(js_runtime_value quickjs "$placed")
    say_ok "QuickJS 已放好（$tag）"
    return 0
  fi
  if qjs_eval_ok /usr/local/bin/qjs; then
    JS_RUNTIME=$(js_runtime_value quickjs /usr/local/bin/qjs)
    say_warn "新的 QuickJS 跑不起来，继续用现在的"
    return 0
  fi
  if try_distro_js; then
    say_ok "官方 QuickJS 跑不起来，已改用系统里的 JavaScript"
    return 0
  fi
  why=$(tr '\n' ' ' < "$errf" 2>/dev/null | cut -c1-180)
  die "QuickJS 在这台鸡上跑不起来。${why}"
}

#----------------------------------------------------------------------
# yt-dlp：去各个网站下视频的主角。装官方版本，网页服务每天自己更新它。
#----------------------------------------------------------------------
ytdlp_runs() {
  [ -x /usr/local/bin/yt-dlp ] || return 1
  /usr/local/bin/yt-dlp --version >/dev/null 2>&1
}

ytdlp_try_asset() {
  asset=$1
  tmp=$WORK/yt-dlp.part
  # shellcheck disable=SC2046
  fetch_first "$tmp" $(github_urls "yt-dlp/yt-dlp/releases/latest/download/$asset") || return 1
  if is_zip "$tmp"; then
    ensure_tool unzip || true
    unpack=$WORK/yt-dlp-unpack
    rm -rf "$unpack"
    unzip_to "$tmp" "$unpack" || return 1
    rm -f "$tmp"
    found=$(find "$unpack" -type f -name 'yt-dlp*' | head -n 1)
    [ -n "$found" ] || return 1
    mv "$found" "$tmp"
    rm -rf "$unpack"
  fi
  is_elf "$tmp" || return 1
  rm -f /usr/local/bin/yt-dlp.new
  cp "$tmp" /usr/local/bin/yt-dlp.new || return 1
  chmod 755 /usr/local/bin/yt-dlp.new || return 1
  rm -f "$tmp"
  if ! /usr/local/bin/yt-dlp.new --version >/dev/null 2>&1; then
    rm -f /usr/local/bin/yt-dlp.new
    return 1
  fi
  mv /usr/local/bin/yt-dlp.new /usr/local/bin/yt-dlp
  return 0
}

# 小内存机器用 3MB 的 Python 版。要先有 python3（3.10 或更新）。
install_ytdlp_zipapp() {
  if ! ensure_tool python3; then
    return 1
  fi
  tmp=$WORK/yt-dlp.zipapp
  # shellcheck disable=SC2046
  fetch_first "$tmp" $(github_urls "yt-dlp/yt-dlp/releases/latest/download/yt-dlp") || return 1
  if ! head -n 1 "$tmp" | grep -q python; then
    rm -f "$tmp"
    return 1
  fi
  rm -f /usr/local/bin/yt-dlp.new
  cp "$tmp" /usr/local/bin/yt-dlp.new || return 1
  chmod 755 /usr/local/bin/yt-dlp.new || return 1
  rm -f "$tmp"
  sync
  drop_page_cache
  ver=$(/usr/local/bin/yt-dlp.new --version 2>/dev/null | head -n 1) || {
    rm -f /usr/local/bin/yt-dlp.new
    return 1
  }
  [ -n "$ver" ] || { rm -f /usr/local/bin/yt-dlp.new; return 1; }
  mv /usr/local/bin/yt-dlp.new /usr/local/bin/yt-dlp
  say_ok "yt-dlp 已装上（$ver）"
  return 0
}

install_ytdlp() {
  say_step "安装 yt-dlp"
  # 官方那个独立程序有 40MB，一运行会先把自己解压出来。64MB 的鸡会被直接打死。
  if low_mem; then
    say_info "内存大约 ${MEM_MB}MB，改用小的 yt-dlp（要有 Python）"
    if install_ytdlp_zipapp; then
      return 0
    fi
    if ytdlp_runs; then
      say_warn "新的 yt-dlp 没换上，继续用现在的"
      return 0
    fi
    if [ $((MEM_MB + SWAP_MB)) -lt 384 ]; then
      die "小的 yt-dlp 没跑起来（系统里的 Python 太旧或装不上）。内存大约 ${MEM_MB}MB，不能再试那个会撑死小鸡的大程序。"
    fi
    say_warn "小的 yt-dlp 没跑起来。有虚拟内存撑着，改试官方独立程序"
  fi
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
  if ytdlp_runs; then
    say_warn "新的 yt-dlp 没换上，继续用现在的"
    return 0
  fi
  die "yt-dlp 跑不起来。架构 $ARCH，系统库 $LIBC，内存大约 ${MEM_MB:-未知}MB。"
}

#----------------------------------------------------------------------
# PO 令牌程序（bgutil-pot，Rust 写的单个程序）和它的 yt-dlp 插件。
# 平时不用，被 YouTube 拦时网页服务才请它出来算令牌。装不上也不影响别的。
#----------------------------------------------------------------------
install_pot() {
  POT_BIN=
  if ! pot_wanted "$ARCH" "$LIBC" "${MEM_MB:-0}" "${SWAP_MB:-0}"; then
    say_info "这台机器（$ARCH / $LIBC / 内存 ${MEM_MB:-?}MB）不装 PO 令牌程序，被拦时跳过这一招。"
    rm -f /usr/local/bin/bgutil-pot
    rm -rf "$POT_PLUGIN_DIR"
    return 0
  fi
  say_step "安装 PO 令牌程序（被 YouTube 拦时自动算令牌用）"
  free_now=$(disk_free_mb /)
  if [ -n "$free_now" ] && [ "$free_now" -lt 400 ]; then
    say_warn "磁盘只剩 ${free_now}MB，先不装 PO 令牌程序"
    return 0
  fi
  asset=$(pot_asset "$ARCH" "$LIBC")
  tag=$(latest_tag jim60105/bgutil-ytdlp-pot-provider-rs)
  [ -n "$tag" ] || tag=v0.8.1
  if [ "${UPDATE_MODE:-}" = 1 ] && [ -x /usr/local/bin/bgutil-pot ] && [ -d "$POT_PLUGIN_DIR/bgutil-pot" ] \
    && [ "$(cat "$CONF_DIR/pot.version" 2>/dev/null)" = "$tag" ] && /usr/local/bin/bgutil-pot --version >/dev/null 2>&1; then
    POT_BIN=/usr/local/bin/bgutil-pot
    say_ok "PO 令牌程序已经是最新（$tag）"
    return 0
  fi
  tmp=$WORK/bgutil-pot
  zipf=$WORK/pot-plugin.zip
  # shellcheck disable=SC2046
  if ! fetch_first "$tmp" $(github_urls "jim60105/bgutil-ytdlp-pot-provider-rs/releases/download/$tag/$asset") \
    || ! is_elf "$tmp"; then
    rm -f "$tmp"
    say_warn "PO 令牌程序没下下来，被拦时跳过这一招"
    [ -x /usr/local/bin/bgutil-pot ] && POT_BIN=/usr/local/bin/bgutil-pot
    return 0
  fi
  chmod 755 "$tmp"
  if ! "$tmp" --version >/dev/null 2>&1; then
    rm -f "$tmp"
    say_warn "PO 令牌程序在这台机器上跑不起来（可能缺 libssl3），被拦时跳过这一招"
    return 0
  fi
  # shellcheck disable=SC2046
  if ! fetch_first "$zipf" $(github_urls "jim60105/bgutil-ytdlp-pot-provider-rs/releases/download/$tag/bgutil-ytdlp-pot-provider-rs.zip") \
    || ! is_zip "$zipf"; then
    rm -f "$tmp" "$zipf"
    say_warn "PO 令牌插件没下下来，被拦时跳过这一招"
    return 0
  fi
  ensure_tool unzip >/dev/null 2>&1 || true
  rm -rf "$POT_PLUGIN_DIR.new"
  if ! unzip_to "$zipf" "$POT_PLUGIN_DIR.new/bgutil-pot" \
    || [ ! -f "$POT_PLUGIN_DIR.new/bgutil-pot/yt_dlp_plugins/extractor/getpot_bgutil_cli.py" ]; then
    rm -rf "$POT_PLUGIN_DIR.new" "$tmp" "$zipf"
    say_warn "PO 令牌插件解压不了（缺 unzip），被拦时跳过这一招"
    return 0
  fi
  # 只用“现算现用”的方式，不开常驻服务，省内存。另一种方式的文件删掉，免得每次报警告。
  rm -f "$POT_PLUGIN_DIR.new/bgutil-pot/yt_dlp_plugins/extractor/getpot_bgutil_http.py"
  rm -rf "$POT_PLUGIN_DIR"
  mv "$POT_PLUGIN_DIR.new" "$POT_PLUGIN_DIR"
  place_elf "$tmp" /usr/local/bin/bgutil-pot
  rm -f "$tmp" "$zipf"
  mkdir -p "$CONF_DIR"
  printf '%s\n' "$tag" > "$CONF_DIR/pot.version"
  POT_BIN=/usr/local/bin/bgutil-pot
  say_ok "PO 令牌程序已放好（$tag）"
}

#----------------------------------------------------------------------
# Cloudflare WARP：被拦时换一个出口 IP。用 wireproxy，在程序里连 WARP，
# 不改系统网络，没有 TUN 的容器也能用。平时不开，网页服务要用时才临时打开。
#----------------------------------------------------------------------
pick_warp_port() {
  for p in 40000 40001 40002 40003 40010 40020; do
    if ! port_busy "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  printf '%s\n' 40000
}

# 临时打开 wireproxy，经过它访问 Cloudflare 的检测页。看到 warp=on 就说明线路通了。
warp_test() {
  port=$1
  have curl || return 2
  /usr/local/bin/wireproxy -c "$WARP_DIR/wireproxy.conf" >"$WORK/warp-test.log" 2>&1 &
  wp=$!
  ok=1
  i=0
  while [ "$i" -lt 6 ]; do
    sleep 2
    out=$(curl -s --max-time 10 --socks5-hostname "127.0.0.1:$port" https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    if printf '%s\n' "$out" | grep -q '^warp=on'; then
      ok=0
      break
    fi
    i=$((i + 1))
  done
  kill "$wp" 2>/dev/null || true
  wait "$wp" 2>/dev/null || true
  return "$ok"
}

install_warp() {
  WARP_CONF=
  WARP_PORT=$(config_get warp_port 2>/dev/null || true)
  [ -n "$WARP_PORT" ] || WARP_PORT=$(pick_warp_port)
  if [ "$WARP_CHOSEN" != 1 ]; then
    say_info "按你的选择，不用 Cloudflare WARP。"
    rm -f /usr/local/bin/wireproxy
    return 0
  fi
  say_step "准备 Cloudflare WARP 线路（被网站拦时换出口 IP 用）"
  asset=$(wireproxy_asset "$ARCH" 2>/dev/null || true)
  [ -n "$asset" ] || { say_warn "这个架构没有 wireproxy，跳过 WARP"; return 0; }
  tag=$(latest_tag whyvl/wireproxy)
  [ -n "$tag" ] || tag=v1.1.3
  tgz=$WORK/wireproxy.tar.gz
  # shellcheck disable=SC2046
  if fetch_first "$tgz" $(github_urls "whyvl/wireproxy/releases/download/$tag/$asset") && is_gzip "$tgz"; then
    mkdir -p "$WORK/wp"
    tar -xzf "$tgz" -C "$WORK/wp" 2>/dev/null || true
    wpbin=$(find "$WORK/wp" -type f -name wireproxy | head -n 1)
    if [ -n "$wpbin" ] && is_elf "$wpbin"; then
      place_elf "$wpbin" /usr/local/bin/wireproxy
    fi
    rm -rf "$WORK/wp" "$tgz"
  fi
  if [ ! -x /usr/local/bin/wireproxy ]; then
    say_warn "wireproxy 没下下来，被拦时跳过 WARP 这一招"
    return 0
  fi
  mkdir -p "$WARP_DIR"
  chmod 700 "$WARP_DIR"
  # 账号只注册一次。以后更新时沿用，不会每次都去 Cloudflare 注册新的。
  if [ ! -s "$WARP_DIR/wgcf-profile.conf" ]; then
    wtag=$(latest_tag ViRb3/wgcf)
    [ -n "$wtag" ] || wtag=v2.3.0
    wasset=$(wgcf_asset "${wtag#v}" "$ARCH" 2>/dev/null || true)
    wbin=$WORK/wgcf
    # shellcheck disable=SC2046
    if [ -z "$wasset" ] || ! fetch_first "$wbin" $(github_urls "ViRb3/wgcf/releases/download/$wtag/$wasset") || ! is_elf "$wbin"; then
      rm -f "$wbin"
      say_warn "wgcf（注册 WARP 用的小工具）没下下来，被拦时跳过 WARP 这一招"
      return 0
    fi
    chmod 755 "$wbin"
    say_info "正在 Cloudflare 匿名注册一个免费 WARP（不用邮箱）…"
    # 注册过程的输出记到 wgcf.log，失败时印最后几行，方便查原因。已经注册过就不再注册。
    if ! (cd "$WARP_DIR" && { [ -s wgcf-account.toml ] || "$wbin" register --accept-tos; } && "$wbin" generate) > "$WARP_DIR/wgcf.log" 2>&1 \
      || [ ! -s "$WARP_DIR/wgcf-profile.conf" ]; then
      rm -f "$wbin"
      say_warn "WARP 注册没成功（可能这台机器连不上 Cloudflare），被拦时跳过这一招。以后再运行 ytdlp-web 回车会重试。"
      tail -n 5 "$WARP_DIR/wgcf.log" 2>/dev/null | sed 's/^/    /'
      chmod 600 "$WARP_DIR/wgcf.log" 2>/dev/null || true
      return 0
    fi
    rm -f "$wbin"
  fi
  {
    printf '%s\n' "WGConfig = $WARP_DIR/wgcf-profile.conf"
    printf '\n%s\n' '[Socks5]'
    printf '%s\n' "BindAddress = 127.0.0.1:$WARP_PORT"
  } > "$WARP_DIR/wireproxy.conf"
  chmod 600 "$WARP_DIR"/* 2>/dev/null || true
  WARP_CONF=$WARP_DIR/wireproxy.conf
  if warp_test "$WARP_PORT"; then
    say_ok "WARP 线路试过了，能用。平时不开，被拦时才自动打开。"
  else
    say_warn "WARP 线路这次没试通（有的机器封了 UDP）。先留着，被拦时还会再试。"
  fi
}

#----------------------------------------------------------------------
# 网页服务本身（server.pl）。整份程序就写在这个脚本里，装的时候原样放出去。
# 这样脚本和网页永远是同一个版本，不会一个新一个旧。
#----------------------------------------------------------------------
#----------------------------------------------------------------------
# 我们自己的 yt-dlp 小插件。yt-dlp 自己搞不定的平台（小红书、B站、抖音、推特图片）
# 由它换一种不用登录的办法拿地址。网页服务把网址写成 ytweb:平台:原链接 交给它。
#----------------------------------------------------------------------
write_plugin() {
  d=$PLUGIN_DIR/ytdlp-web/yt_dlp_plugins/extractor
  mkdir -p "$d"
  cat > "$d/ytdlp_web.py.new" <<'YTDLP_WEB_PLUGIN_EOF'
# ytdlp-web 自带的小插件：yt-dlp 自己搞不定的几个平台，由这里换一种不用登录的办法拿视频/图片地址。
#   ytweb:xhs:<链接>     小红书：用手机浏览器的身份打开分享页，从页面里的数据拿视频（优先 h264）或图片
#   ytweb:bili:<链接>    B站：手机版页面 + html5 播放接口，拿 Mac 能直接播的 mp4（不登录最高 720p）
#   ytweb:douyin:<链接>  抖音：分享页里的数据，拿无水印视频或图片；拿不到就报 YTWEB_NEED_COOKIES
#   ytweb:ximg:<链接>    推特/X：纯图片推文，从公开的 fxtwitter/vxtwitter 接口拿原图
# 报错里的 YTWEB_xxx 暗号由网页程序翻译成中文。
import json
import re
import time
import urllib.parse

from yt_dlp.extractor.common import InfoExtractor
from yt_dlp.utils import ExtractorError

MOBILE_UA = ('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
             '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1')


def _fail(code, msg=''):
    raise ExtractorError(f'{code} {msg}'.strip(), expected=True)


def _json_after(html, marker):
    i = html.find(marker)
    if i < 0:
        return None
    i = html.find('{', i)
    if i < 0:
        return None
    depth, instr, esc = 0, False, False
    for j in range(i, len(html)):
        ch = html[j]
        if instr:
            if esc:
                esc = False
            elif ch == '\\':
                esc = True
            elif ch == '"':
                instr = False
            continue
        if ch == '"':
            instr = True
        elif ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                raw = html[i:j + 1]
                raw = re.sub(r'(?<=[:\[,])\s*undefined\b', 'null', raw)
                try:
                    return json.loads(raw)
                except ValueError:
                    return None
    return None


def _walk(o, key):
    """在一大坨数据里找第一个名叫 key 的东西。"""
    stack = [o]
    while stack:
        x = stack.pop(0)
        if isinstance(x, dict):
            if key in x and x[key]:
                return x[key]
            stack.extend(v for v in x.values() if isinstance(v, (dict, list)))
        elif isinstance(x, list):
            stack.extend(v for v in x if isinstance(v, (dict, list)))
    return None


class YtdlpWebIE(InfoExtractor):
    IE_NAME = 'ytweb'
    _VALID_URL = r'ytweb:(?P<plat>xhs|bili|douyin|ximg):(?P<url>.+)'
    _TESTS = []

    def _real_extract(self, url):
        plat, link = self._match_valid_url(url).group('plat', 'url')
        return getattr(self, '_' + plat)(link)

    def _get(self, url, vid, headers=None, note=None, fatal=True):
        h = {'User-Agent': MOBILE_UA}
        h.update(headers or {})
        return self._download_webpage_handle(url, vid, note=note or '打开页面', headers=h, fatal=fatal)

    def _images(self, vid, title, urls, headers=None):
        urls = [u for u in urls if u]
        if not urls:
            _fail('YTWEB_NO_MEDIA')
        entries = []
        for n, u in enumerate(urls, 1):
            ext = 'png' if '.png' in u.split('?')[0] else 'webp' if 'format=webp' in u or '.webp' in u.split('?')[0] else 'jpg'
            entries.append({
                'id': f'{vid}_{n}', 'title': title, 'ext': ext,
                'formats': [{'url': u, 'ext': ext, 'format_id': 'image', 'http_headers': headers or {}}],
            })
        if len(entries) == 1:
            return entries[0]
        return {'_type': 'playlist', 'id': vid, 'title': title, 'entries': entries}

    # ---------------- 小红书 ----------------
    def _xhs(self, link):
        page, h = self._get(link, 'xhs', note='打开小红书分享页')
        final = h.url
        if re.search(r'/login|/website-login|captcha|/404', final):
            _fail('YTWEB_NEED_COOKIES', 'xhs login page')
        nid = self._search_regex(r'/(?:explore|discovery/item|item)/([0-9a-f]{24})', final, 'note id', default='xhs')
        st = _json_after(page, '__INITIAL_STATE__')
        note = None
        if st:
            nd = st.get('noteData') or {}
            note = (nd.get('data') or {}).get('noteData')
            if not note:
                m = (st.get('note') or {}).get('noteDetailMap') or {}
                for v in m.values():
                    if isinstance(v, dict) and v.get('note'):
                        note = v['note']
                        break
        if not note or not (note.get('type') or note.get('imageList') or note.get('video')):
            if '你访问的页面不见了' in page or '笔记不存在' in page or 'Sorry, This Page Isn' in page:
                _fail('YTWEB_GONE')
            _fail('YTWEB_NEED_COOKIES', 'xhs no note data')
        title = (note.get('title') or note.get('desc') or '小红书笔记').strip()[:80] or '小红书笔记'
        hdr = {'Referer': 'https://www.xiaohongshu.com/', 'User-Agent': MOBILE_UA}
        if note.get('type') == 'video' and note.get('video'):
            stream = ((note['video'].get('media') or {}).get('stream')) or {}
            fmts = []
            for codec, vc in (('h264', 'avc1'), ('h265', 'hvc1'), ('h266', 'vvc1'), ('av1', 'av01')):
                for s in stream.get(codec) or []:
                    u = s.get('masterUrl') or (s.get('backupUrls') or [None])[0]
                    if not u:
                        continue
                    fmts.append({
                        'url': u.replace('http://', 'https://', 1), 'ext': 'mp4', 'format_id': f'{codec}-{s.get("height") or 0}',
                        'vcodec': vc, 'acodec': 'mp4a', 'width': s.get('width'), 'height': s.get('height'),
                        'tbr': (s.get('avgBitrate') or 0) / 1000 or None, 'filesize': s.get('size'), 'http_headers': hdr,
                    })
            if not fmts:
                key = (note['video'].get('consumer') or {}).get('originVideoKey')
                if key:
                    fmts.append({'url': f'https://sns-video-bd.xhscdn.com/{key}', 'ext': 'mp4', 'format_id': 'origin', 'http_headers': hdr})
            if not fmts:
                _fail('YTWEB_NEED_COOKIES', 'xhs no video url')
            dur = (note['video'].get('capa') or {}).get('duration')
            return {'id': nid, 'title': title, 'formats': fmts, 'duration': dur}
        urls = []
        for im in note.get('imageList') or []:
            u = im.get('urlDefault') or im.get('url') or ''
            infos = im.get('infoList') or []
            if not u and infos:
                u = infos[-1].get('url') or ''
            urls.append(u.replace('http://', 'https://', 1))
        if not any(urls):
            _fail('YTWEB_NO_MEDIA')
        return self._images(nid, title, urls, hdr)

    # ---------------- B站 ----------------
    def _bili(self, link):
        if re.search(r'b23\.tv|bili2233\.cn', link):
            _, h = self._get(link, 'b23', note='展开 B 站短链接')
            link = h.url
        m = re.search(r'(BV[0-9A-Za-z]{10})', link)
        if not m:
            _fail('YTWEB_BAD_LINK')
        bv = m.group(1)
        p = int(self._search_regex(r'[?&]p=(\d+)', link, 'page', default='1'))
        # 先拿匿名访客 cookie（buvid3/buvid4），B 站风控会看这个。
        self._get('https://m.bilibili.com/', bv, note='拿 B 站访客 cookie', fatal=False)
        spi = self._download_json('https://api.bilibili.com/x/frontend/finger/spi', bv, note='拿 buvid4', fatal=False,
                                  headers={'User-Agent': MOBILE_UA, 'Referer': 'https://m.bilibili.com/'}) or {}
        d = spi.get('data') or {}
        if d.get('b_3'):
            self._set_cookie('.bilibili.com', 'buvid3', d['b_3'])
        if d.get('b_4'):
            self._set_cookie('.bilibili.com', 'buvid4', d['b_4'])
        page, _ = self._get(f'https://m.bilibili.com/video/{bv}', bv, note='打开 B 站手机版页面',
                            headers={'Referer': 'https://m.bilibili.com/'})
        st = _json_after(page, '__INITIAL_STATE__') or {}
        info = (st.get('video') or {}).get('viewInfo') or {}
        if not info:
            if '视频去哪了' in page or '啊叻？视频不见了' in page:
                _fail('YTWEB_GONE')
            _fail('YTWEB_NEED_COOKIES', 'bili no viewInfo')
        pages = info.get('pages') or []
        cid = info.get('cid')
        title = info.get('title') or bv
        dur = info.get('duration')
        if pages and 1 <= p <= len(pages):
            cid = pages[p - 1].get('cid') or cid
            dur = pages[p - 1].get('duration') or dur
            if len(pages) > 1:
                title = f'{title} P{p} {pages[p - 1].get("part") or ""}'.strip()
        hdr = {'Referer': 'https://m.bilibili.com/', 'User-Agent': MOBILE_UA}
        fmts = []
        for qn in (80, 64):
            api = (f'https://api.bilibili.com/x/player/playurl?bvid={bv}&cid={cid}&qn={qn}'
                   '&platform=html5&high_quality=1&fnval=1&fnver=0&fourk=0')
            j = self._download_json(api, bv, note=f'问 B 站要播放地址（{qn}）', headers=hdr, fatal=False) or {}
            data = j.get('data') or {}
            for n, du in enumerate(data.get('durl') or []):
                if n > 0:
                    break
                q = data.get('quality') or qn
                if any(f['format_id'] == f'mp4-{q}' for f in fmts):
                    continue
                height = {16: 360, 32: 480, 64: 720, 80: 1080, 112: 1080, 116: 1080}.get(q)
                fmts.append({'url': du.get('url'), 'ext': 'mp4', 'format_id': f'mp4-{q}', 'vcodec': 'avc1', 'acodec': 'mp4a',
                             'height': height, 'filesize': du.get('size'), 'http_headers': hdr})
            if fmts:
                break
        if not fmts:
            for u in (st.get('video') or {}).get('playUrlInfo') or []:
                if u.get('url'):
                    fmts.append({'url': u['url'], 'ext': 'mp4', 'format_id': 'mp4-page', 'vcodec': 'avc1', 'acodec': 'mp4a',
                                 'height': 360, 'http_headers': hdr})
        if not fmts:
            _fail('YTWEB_NEED_COOKIES', 'bili no playurl')
        return {'id': bv, 'title': title, 'formats': fmts, 'duration': dur}

    # ---------------- 抖音 ----------------
    def _douyin(self, link):
        aid = self._search_regex(r'(?:/video/|/note/|/slides/|modal_id=|aweme_id=)(\d{15,21})', link, 'id', default=None)
        if not aid:
            _, h = self._get(link, 'douyin', note='展开抖音短链接')
            aid = self._search_regex(r'(?:/video/|/note/|/slides/|modal_id=|aweme_id=)(\d{15,21})', h.url, 'id', default=None)
        if not aid:
            _fail('YTWEB_BAD_LINK')
        item = None
        # 分享页偶尔会少给数据，多试几次（每次间隔 1 秒）。
        for kind in ('video', 'note', 'video', 'note'):
            if item:
                break
            got = self._get(f'https://www.iesdouyin.com/share/{kind}/{aid}/', aid, note='打开抖音分享页', fatal=False)
            page = got[0] if got else None
            if not page:
                time.sleep(1)
                continue
            rd = _json_after(page, '_ROUTER_DATA') or {}
            res = _walk(rd, 'videoInfoRes') or {}
            lst = res.get('item_list') if isinstance(res, dict) else None
            if lst:
                item = lst[0]
                break
            if isinstance(res, dict) and res.get('filter_list'):
                _fail('YTWEB_GONE')
            time.sleep(1)
        if not item:
            _fail('YTWEB_NEED_COOKIES', 'douyin share page has no data')
        # 文件名：优先用作品的文字描述；没写描述的，用「作者 的抖音 作品编号」。
        title = re.sub(r'\s+', ' ', item.get('desc') or '').strip()[:80].strip()
        if not title:
            nick = re.sub(r'\s+', ' ', (item.get('author') or {}).get('nickname') or '').strip()[:40]
            title = f'{nick} 的抖音 {aid}' if nick else f'抖音 {aid}'
        hdr = {'User-Agent': MOBILE_UA, 'Referer': 'https://www.douyin.com/'}
        imgs = item.get('images') or []
        if imgs:
            return self._images(aid, title, [(i.get('url_list') or [''])[-1] for i in imgs], hdr)
        v = item.get('video') or {}
        fmts = []
        # 分享页有时会带 bit_rate 列表（不同清晰度、H.264/H.265 各一份）。有就全列出来，让 yt-dlp 按 H.264 优先挑。
        for b in v.get('bit_rate') or []:
            pa = b.get('play_addr') or {}
            bu = (pa.get('url_list') or [None])[0]
            if not bu:
                continue
            h265 = bool(b.get('is_h265') or b.get('is_bytevc1'))
            fmts.append({'url': bu.replace('playwm', 'play'), 'ext': 'mp4', 'format_id': f'br-{b.get("gear_name") or len(fmts)}',
                         'vcodec': 'hvc1' if h265 else 'avc1', 'acodec': 'mp4a', 'tbr': (b.get('bit_rate') or 0) / 1000 or None,
                         'width': pa.get('width'), 'height': pa.get('height'), 'filesize': pa.get('data_size'), 'http_headers': hdr})
        urls = (v.get('play_addr') or {}).get('url_list') or []
        if urls:
            # 去水印：playwm → play。清晰度参数实测（2026-10）：
            #   ratio=default  原视频的分辨率和码率（样例 496x864、2.4Mbps）←— 优先用它
            #   ratio=720p/1080p/2160p  其实是压缩过的一档（样例 480x836、0.8Mbps），留着备用
            base = urls[0].replace('playwm', 'play')
            for ratio, q in (('default', 2), ('1080p', 1)):
                u = re.sub(r'ratio=\w+', f'ratio={ratio}', base) if 'ratio=' in base else f'{base}&ratio={ratio}'
                fmts.append({'url': u, 'ext': 'mp4', 'format_id': f'nowm-{ratio}', 'vcodec': 'avc1', 'acodec': 'mp4a',
                             'quality': q, 'height': v.get('height'), 'width': v.get('width'), 'http_headers': hdr})
        if not fmts:
            _fail('YTWEB_NO_MEDIA')
        return {'id': aid, 'title': title, 'duration': (v.get('duration') or 0) / 1000 or None, 'formats': fmts}

    # ---------------- 推特/X 图片 ----------------
    def _ximg(self, link):
        tid = self._search_regex(r'/status(?:es)?/(\d+)', link, 'tweet id', default=None)
        if not tid:
            _fail('YTWEB_BAD_LINK')
        tw = None
        j = self._download_json(f'https://api.fxtwitter.com/status/{tid}', tid, note='问 fxtwitter 要图片', fatal=False) or {}
        if j.get('tweet'):
            t = j['tweet']
            media = t.get('media') or {}
            tw = {'text': t.get('text') or '', 'author': (t.get('author') or {}).get('name') or '',
                  'photos': [p.get('url') for p in media.get('photos') or []],
                  'videos': [v.get('url') for v in media.get('videos') or []]}
        elif j.get('code') == 404:
            _fail('YTWEB_GONE')
        if tw is None:
            j = self._download_json(f'https://api.vxtwitter.com/Twitter/status/{tid}', tid, note='问 vxtwitter 要图片', fatal=False) or {}
            if j.get('tweetID') or j.get('text') is not None:
                ms = j.get('media_extended') or []
                tw = {'text': j.get('text') or '', 'author': j.get('user_name') or '',
                      'photos': [m.get('url') for m in ms if m.get('type') == 'image'],
                      'videos': [m.get('url') for m in ms if m.get('type') in ('video', 'gif')]}
        if tw is None:
            _fail('YTWEB_NEED_COOKIES', 'x api unavailable')
        title = (f'{tw["author"]} - ' if tw['author'] else '') + (re.sub(r'https?://\S+', '', tw['text']).strip()[:60] or tid)
        if tw['photos']:
            urls = []
            for u in tw['photos']:
                if 'pbs.twimg.com/media/' in u and 'name=' not in u:
                    u = u + ('&' if '?' in u else '?') + 'name=orig'
                urls.append(u)
            return self._images(tid, title, urls)
        if tw['videos']:
            return {'id': tid, 'title': title, 'formats': [{'url': tw['videos'][0], 'ext': 'mp4', 'format_id': 'mp4'}]}
        _fail('YTWEB_NO_MEDIA')
YTDLP_WEB_PLUGIN_EOF
  mv "$d/ytdlp_web.py.new" "$d/ytdlp_web.py"
  chmod 644 "$d/ytdlp_web.py"
}

write_server() {
  mkdir -p "$LIB_DIR"
  cat > "$LIB_DIR/server.pl.new" <<'YTDLP_WEB_SERVER_EOF'
#!/usr/bin/perl
#======================================================================
# ytdlp-web 网页服务
#----------------------------------------------------------------------
# 这是 install.sh 装到 VPS 上的小网页。Mac 浏览器打开的就是它。
# 你贴一个链接（或者 App 里「分享 → 复制链接」的整段文字），它让 yt-dlp 把视频下到 VPS，
# 下完马上让浏览器存到 Mac，传完以后自动把 VPS 上的文件删掉。只用 Perl 自带的模块，64MB 小鸡也跑得动。
# 支持 YouTube、抖音、小红书、B站、TikTok、推特/X、Instagram（以及 yt-dlp 认得的其他网站）。
#
# 名词小词典
#   网页服务  一直在 VPS 上跑的这个程序，听一个端口，浏览器连进来
#   任务      你贴一次链接就是一个任务。每个任务在 jobs 里有一个自己的文件夹
#   yt-dlp    真正去 YouTube 下视频的程序
#   办法      被 YouTube 拦住时换的下载方式：换客户端、IPv6、PO 令牌、WARP、cookies
#   PO 令牌   YouTube 用来确认“你是真浏览器”的一串码，bgutil-pot 程序会自动算
#   WARP      Cloudflare 的免费线路。换一个 YouTube 不拦的出口 IP
#   cookies   浏览器里的登录记录。上传以后 yt-dlp 就像登录了你的 YouTube 小号
#   断点续传  网断了，浏览器从断的地方接着下，不用从头来（HTTP 的 Range）
#   会话      登录成功后浏览器拿到的通行证（一个 cookie），30 天有效
#   送达      文件的每一个字节都已经发给了浏览器
#   平台      链接是哪个网站的：youtube douyin xhs(小红书) bili(B站) tiktok x(推特) ig(Instagram) other
#   分享文字  App 里「复制链接」得到的一整段话，里面夹着一个网址。我们自动把网址挑出来
#   短链接    v.douyin.com、xhslink.cn、b23.tv 这种，打开后会跳到真正的地址
#   插件      ytdlp_web.py，装在 plugins 文件夹。yt-dlp 自己搞不定的平台由它换办法拿地址，
#             网址写成 ytweb:平台:原链接 就会交给它
#   图文      只有图片没有视频的帖子。一张直接存，多张打成一个 zip
#   H.264     Mac 自带播放器（QuickTime）能放的视频格式。VP9/AV1 放不了，要转码
#   转码      把视频重新编码成 H.264。1 核小鸡很慢，大概和视频一样长甚至更久
#   IPv4/IPv6 两种网络地址。同一个网站，换一种地址去连，有时就不被拦了
#======================================================================
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use POSIX qw(:sys_wait_h setsid strftime setlocale LC_ALL);
use Fcntl qw(:flock O_WRONLY O_CREAT O_APPEND);
use File::Path qw(make_path remove_tree);

my $VERSION = '2.1.2';
setlocale(LC_ALL, 'C');
$SIG{PIPE} = 'IGNORE';

#----------------------------------------------------------------------
# 读配置。配置是 install.sh 写的 key=value 文件，一行一个。
#----------------------------------------------------------------------
my $CONF_FILE = $ARGV[0] || '/etc/ytdlp-web/web.conf';
my %C = (
  listen      => '0.0.0.0',
  data        => '/var/lib/ytdlp-web',
  keep_hours  => 6,      # 没传到 Mac 的文件，最多在 VPS 上留几个小时
  grace       => 120,    # 传完以后再等几秒才删，给浏览器补最后一点的机会
  ytdlp       => '/usr/local/bin/yt-dlp',
  js          => '',
  ffmpeg      => '',
  wireproxy   => '',
  warp_conf   => '',
  warp_port   => 40000,
  pot         => '',
  pot_plugins => '',
  plugins     => '',     # 我们自己的 yt-dlp 插件目录（小红书、B站、抖音、推特图片）
  cookies     => '/etc/ytdlp-web/cookies.txt',
  min_free_mb => 300,
  update_hours => 24,
  sweep_secs  => 30,     # 多久检查一次该删的文件
);
read_conf($CONF_FILE);

sub read_conf {
  my ($f) = @_;
  open(my $fh, '<', $f) or die "读不到配置文件 $f\n";
  while (my $l = <$fh>) {
    chomp $l;
    $l =~ s/\r$//;
    next if $l =~ /^\s*(#|$)/;
    my ($k, $v) = split /=/, $l, 2;
    next unless defined $v;
    $C{$k} = $v;
  }
  close $fh;
  die "配置里没有端口 port\n" unless ($C{port} || '') =~ /^\d+$/;
  die "配置里没有密码 pass_hash\n" unless ($C{pass_hash} || '') =~ /^\$/;
  $C{user} = 'admin' unless defined $C{user} && length $C{user};
}

my $DATA  = $C{data};
my $JOBS  = "$DATA/jobs";
my $STATE = "$DATA/state";
make_path($JOBS, $STATE, "$DATA/tmp", "$DATA/cache", "$DATA/home");
chmod 0700, $DATA;

#----------------------------------------------------------------------
# 小工具：读写文件、随机数、时间、JSON。
#----------------------------------------------------------------------
sub slurp {
  my ($f) = @_;
  open(my $fh, '<', $f) or return undef;
  local $/;
  my $d = <$fh>;
  close $fh;
  return $d;
}

# 先写到旁边的临时文件再改名，别的进程永远读不到写了一半的文件。
sub spit {
  my ($f, $d) = @_;
  my $t = "$f.tmp$$";
  open(my $fh, '>', $t) or return 0;
  print $fh $d;
  close $fh;
  rename($t, $f) or do { unlink $t; return 0 };
  return 1;
}

sub kv_read {
  my ($f) = @_;
  my %h;
  my $d = slurp($f);
  return \%h unless defined $d;
  for my $l (split /\n/, $d) {
    my ($k, $v) = split /=/, $l, 2;
    next unless defined $v;
    $v =~ s/\\n/\n/g;
    $h{$k} = $v;
  }
  return \%h;
}

sub kv_write {
  my ($f, $h) = @_;
  my $d = '';
  for my $k (sort keys %$h) {
    my $v = defined $h->{$k} ? $h->{$k} : '';
    $v =~ s/\r//g;
    $v =~ s/\n/\\n/g;
    $d .= "$k=$v\n";
  }
  return spit($f, $d);
}

sub kv_update {
  my ($f, %new) = @_;
  my $h = kv_read($f);
  $h->{$_} = $new{$_} for keys %new;
  kv_write($f, $h);
}

sub rand_hex {
  my ($n) = @_;
  open(my $fh, '<', '/dev/urandom') or die "没有 /dev/urandom\n";
  my $b = '';
  read($fh, $b, $n);
  close $fh;
  return unpack('H*', $b);
}

sub json {
  my ($v) = @_;
  if (ref $v eq 'HASH') {
    return '{' . join(',', map { json_str($_) . ':' . json($v->{$_}) } sort keys %$v) . '}';
  }
  if (ref $v eq 'ARRAY') {
    return '[' . join(',', map { json($_) } @$v) . ']';
  }
  if (ref $v eq 'SCALAR') {
    return $$v;
  }
  return json_str($v);
}

sub json_str {
  my ($s) = @_;
  $s = '' unless defined $s;
  $s =~ s/(["\\])/\\$1/g;
  $s =~ s/\n/\\n/g;
  $s =~ s/\r/\\r/g;
  $s =~ s/\t/\\t/g;
  $s =~ s/([\x00-\x1f\x7f])/sprintf('\\u%04x', ord($1))/ge;
  $s =~ s/</\\u003c/g;
  return "\"$s\"";
}

sub num  { my $n = shift; $n = 0 unless defined $n && $n =~ /^-?\d+(\.\d+)?$/; return \$n; }
sub bool { return \($_[0] ? 'true' : 'false'); }

sub url_decode {
  my ($s) = @_;
  return '' unless defined $s;
  $s =~ tr/+/ /;
  $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
  return $s;
}

sub parse_form {
  my ($s) = @_;
  my %h;
  for my $p (split /&/, $s || '') {
    my ($k, $v) = split /=/, $p, 2;
    $h{url_decode($k)} = url_decode($v);
  }
  return \%h;
}

sub pct_encode {
  my ($s) = @_;
  $s =~ s/([^A-Za-z0-9._~-])/sprintf('%%%02X', ord($1))/ge;
  return $s;
}

sub html_esc {
  my ($s) = @_;
  $s = '' unless defined $s;
  $s =~ s/&/&amp;/g;
  $s =~ s/</&lt;/g;
  $s =~ s/>/&gt;/g;
  $s =~ s/"/&quot;/g;
  return $s;
}

sub http_date { return strftime('%a, %d %b %Y %H:%M:%S GMT', gmtime($_[0])); }

sub human_size {
  my ($b) = @_;
  return '' unless defined $b && $b =~ /^\d+(\.\d+)?$/;
  return sprintf('%.1f GB', $b / 1073741824) if $b >= 1073741824;
  return sprintf('%.1f MB', $b / 1048576) if $b >= 1048576;
  return sprintf('%.0f KB', $b / 1024);
}

sub human_secs {
  my ($s) = @_;
  return '' unless defined $s && $s =~ /^\d+(\.\d+)?$/;
  $s = int($s);
  return sprintf('%d 小时 %d 分', int($s / 3600), int(($s % 3600) / 60)) if $s >= 3600;
  return sprintf('%d 分 %d 秒', int($s / 60), $s % 60) if $s >= 60;
  return "$s 秒";
}

sub logline {
  my ($msg) = @_;
  my $t = strftime('%Y-%m-%d %H:%M:%S', localtime);
  print STDERR "[$t] $msg\n";
}

sub disk_free_mb {
  my ($dir) = @_;
  my $out = `df -Pk '$dir' 2>/dev/null`;
  my @l = split /\n/, $out;
  return -1 unless @l >= 2;
  my @f = split /\s+/, $l[-1];
  return -1 unless defined $f[3] && $f[3] =~ /^\d+$/;
  return int($f[3] / 1024);
}

#----------------------------------------------------------------------
# 读浏览器发来的请求。只收一个请求，回完就断开，简单可靠。
#----------------------------------------------------------------------
sub read_request {
  my ($c) = @_;
  my $buf = '';
  my $sel = IO::Select->new($c);
  my $deadline = time + 20;
  while ($buf !~ /\r?\n\r?\n/) {
    return undef if length($buf) > 32768;
    my $left = $deadline - time;
    return undef if $left <= 0;
    return undef unless $sel->can_read($left);
    my $n = sysread($c, $buf, 8192, length $buf);
    return undef unless $n;
  }
  my ($head, $rest) = split /\r?\n\r?\n/, $buf, 2;
  $rest = '' unless defined $rest;
  my @lines = split /\r?\n/, $head;
  my $first = shift @lines;
  return undef unless $first =~ m{^([A-Z]+) (\S+) HTTP/\d\.\d$};
  my ($method, $target) = ($1, $2);
  my %h;
  for my $l (@lines) {
    next unless $l =~ /^([^:]+):\s*(.*?)\s*$/;
    $h{lc $1} = $2;
  }
  my ($path, $query) = split /\?/, $target, 2;
  my $r = {
    method  => $method,
    path    => $path,
    query   => parse_form($query),
    headers => \%h,
    body    => '',
    ip      => ($c->peerhost || '?'),
  };
  my $len = $h{'content-length'} || 0;
  if ($len =~ /^\d+$/ && $len > 0) {
    return { %$r, too_big => 1 } if $len > 2 * 1024 * 1024;
    my $body = $rest;
    while (length($body) < $len) {
      my $left = $deadline + 20 - time;
      return undef if $left <= 0;
      return undef unless $sel->can_read($left);
      my $n = sysread($c, $body, 65536, length $body);
      return undef unless $n;
    }
    $r->{body} = substr($body, 0, $len);
  }
  return $r;
}

# 一直写，直到全部写完。浏览器 2 分钟都不收数据，就当它走了。
sub write_all {
  my ($c, $data) = @_;
  my $sel = IO::Select->new($c);
  my ($off, $len) = (0, length $data);
  while ($off < $len) {
    return 0 unless $sel->can_write(120);
    my $n = syswrite($c, $data, $len - $off, $off);
    return 0 unless defined $n && $n > 0;
    $off += $n;
  }
  return 1;
}

my %REASON = (200 => 'OK', 206 => 'Partial Content', 302 => 'Found', 400 => 'Bad Request',
  401 => 'Unauthorized', 403 => 'Forbidden', 404 => 'Not Found', 405 => 'Method Not Allowed',
  413 => 'Payload Too Large', 416 => 'Range Not Satisfiable', 429 => 'Too Many Requests',
  500 => 'Internal Server Error', 503 => 'Service Unavailable');

sub head_text {
  my ($code, $hdr) = @_;
  my $s = "HTTP/1.1 $code " . ($REASON{$code} || 'OK') . "\r\n";
  my %h = (
    'Connection' => 'close',
    'X-Content-Type-Options' => 'nosniff',
    'X-Frame-Options' => 'SAMEORIGIN',
    'Referrer-Policy' => 'no-referrer',
    %$hdr,
  );
  $s .= "$_: $h{$_}\r\n" for sort keys %h;
  return "$s\r\n";
}

sub respond {
  my ($c, $r, $code, $type, $body, $extra) = @_;
  $body = '' unless defined $body;
  my %h = ('Content-Type' => $type, 'Content-Length' => length($body), 'Cache-Control' => 'no-store', %{ $extra || {} });
  write_all($c, head_text($code, \%h) . (($r && $r->{method} eq 'HEAD') ? '' : $body));
}

sub respond_json { my ($c, $r, $code, $v) = @_; respond($c, $r, $code, 'application/json; charset=utf-8', json($v)); }
sub redirect     { my ($c, $r, $to, $extra) = @_; respond($c, $r, 302, 'text/plain; charset=utf-8', '', { Location => $to, %{ $extra || {} } }); }

#----------------------------------------------------------------------
# 登录：密码对了发一张 30 天的通行证。错 5 次要等 10 分钟。
#----------------------------------------------------------------------
my $SESS_FILE = "$STATE/sessions";
my $FAIL_FILE = "$STATE/login-fails";

sub with_lock {
  my ($name, $code) = @_;
  open(my $lk, '>>', "$STATE/$name.lock") or return $code->();
  flock($lk, LOCK_EX);
  my @r = $code->();
  close $lk;
  return wantarray ? @r : $r[0];
}

sub cookie_token {
  my ($r) = @_;
  my $ck = $r->{headers}{cookie} || '';
  return $1 if $ck =~ /(?:^|;\s*)ytw=([0-9a-f]{64})/;
  return '';
}

sub session_ok {
  my ($r) = @_;
  my $tok = cookie_token($r);
  return 0 unless $tok;
  my $d = slurp($SESS_FILE) || '';
  my $now = time;
  for my $l (split /\n/, $d) {
    my ($t, $exp) = split / /, $l;
    return 1 if defined $exp && $t eq $tok && $exp > $now;
  }
  return 0;
}

sub session_add {
  my $tok = rand_hex(32);
  my $now = time;
  with_lock('sessions', sub {
    my $d = slurp($SESS_FILE) || '';
    my @keep = grep { my ($t, $e) = split / /; defined $e && $e > $now } split /\n/, $d;
    @keep = @keep[-50 .. -1] if @keep > 50;
    push @keep, "$tok " . ($now + 30 * 86400);
    spit($SESS_FILE, join("\n", @keep) . "\n");
    chmod 0600, $SESS_FILE;
  });
  return $tok;
}

sub session_del {
  my ($tok) = @_;
  return unless $tok;
  with_lock('sessions', sub {
    my $d = slurp($SESS_FILE) || '';
    my @keep = grep { (split / /)[0] ne $tok } split /\n/, $d;
    spit($SESS_FILE, join("\n", @keep) . (@keep ? "\n" : ''));
  });
}

sub login_blocked {
  my ($ip) = @_;
  my $d = slurp($FAIL_FILE) || '';
  my $n = grep { my ($i, $t) = split / /; $i eq $ip && $t > time - 600 } split /\n/, $d;
  return $n >= 5;
}

sub login_failed {
  my ($ip) = @_;
  with_lock('fails', sub {
    my $d = slurp($FAIL_FILE) || '';
    my @keep = grep { my ($i, $t) = split / /; defined $t && $t > time - 600 } split /\n/, $d;
    push @keep, "$ip " . time;
    @keep = @keep[-500 .. -1] if @keep > 500;
    spit($FAIL_FILE, join("\n", @keep) . "\n");
  });
}

sub password_ok {
  my ($user, $pass) = @_;
  return 0 unless defined $user && defined $pass && $user eq $C{user};
  my $h = crypt($pass, $C{pass_hash});
  return defined $h && $h eq $C{pass_hash};
}

#----------------------------------------------------------------------
# 任务的样子：jobs/<编号>/ 里面放
#   meta    链接、画质、什么时候贴的
#   status  现在到哪一步了（网页每秒来读一次）
#   log     yt-dlp 的原始输出，出错时排查用
#   sent    浏览器已经拿走了哪几段（断点续传会分好几段）
#   视频文件本身
#----------------------------------------------------------------------
my %QUALITY = (
  mac  => 'Mac 能直接播放的最高画质',
  best => '最高画质（4K/8K）',
  p720 => '720p 小文件',
  m4a  => '只要声音（m4a）',
  mp3  => '只要声音（mp3）',
);

#----------------------------------------------------------------------
# 认平台。re 认链接里的网站，ck 认 cookies 文件里的网站，open 是导出 cookies 时要打开的网址。
#----------------------------------------------------------------------
my @PLATFORMS = (
  { key => 'youtube', name => 'YouTube',   re => qr/(?:^|\.)(?:youtube\.com|youtu\.be|youtube-nocookie\.com)$/i, ck => qr/(?:^|\.)youtube\.com$/i,
    open => 'https://www.youtube.com/robots.txt' },
  { key => 'douyin',  name => '抖音',      re => qr/(?:^|\.)(?:douyin\.com|iesdouyin\.com)$/i, ck => qr/(?:^|\.)(?:douyin\.com|iesdouyin\.com)$/i,
    open => 'https://www.douyin.com/' },
  { key => 'xhs',     name => '小红书',    re => qr/(?:^|\.)(?:xiaohongshu\.com|xhslink\.com|xhslink\.cn)$/i, ck => qr/(?:^|\.)xiaohongshu\.com$/i,
    open => 'https://www.xiaohongshu.com/explore' },
  { key => 'bili',    name => 'B站',       re => qr/(?:^|\.)(?:bilibili\.com|b23\.tv|bili2233\.cn)$/i, ck => qr/(?:^|\.)bilibili\.com$/i,
    open => 'https://www.bilibili.com/' },
  { key => 'tiktok',  name => 'TikTok',    re => qr/(?:^|\.)tiktok\.com$/i, ck => qr/(?:^|\.)tiktok\.com$/i,
    open => 'https://www.tiktok.com/' },
  { key => 'x',       name => '推特/X',    re => qr/(?:^|\.)(?:x\.com|twitter\.com|fxtwitter\.com|vxtwitter\.com|fixupx\.com)$/i, ck => qr/(?:^|\.)(?:x\.com|twitter\.com)$/i,
    open => 'https://x.com/' },
  { key => 'ig',      name => 'Instagram', re => qr/(?:^|\.)(?:instagram\.com|instagr\.am)$/i, ck => qr/(?:^|\.)instagram\.com$/i,
    open => 'https://www.instagram.com/' },
);
my %PLAT = map { $_->{key} => $_ } @PLATFORMS;

sub url_host {
  my ($u) = @_;
  return '' unless defined $u && $u =~ m{^https?://(?:[^/\@]*\@)?([^/:?#]+)}i;
  return lc $1;
}

sub platform_of {
  my ($u) = @_;
  my $h = url_host($u);
  for my $p (@PLATFORMS) { return $p->{key} if $h =~ $p->{re}; }
  return 'other';
}

sub plat_name { my ($k) = @_; return $PLAT{ $k || '' } ? $PLAT{$k}{name} : '这个网站'; }

# cookies 文件里一行的网站属于哪个平台。
sub cookie_plat {
  my ($domain) = @_;
  $domain = lc($domain || '');
  $domain =~ s/^#httponly_//;
  $domain =~ s/^\.//;
  for my $p (@PLATFORMS) { return $p->{key} if $domain =~ $p->{ck}; }
  return '';
}

#----------------------------------------------------------------------
# 从一段话里挑出网址。App 的分享文字像这样：
#   6.99 复制打开抖音，看看【某某的作品】…… https://v.douyin.com/qZn98J7Dp00/ 8@5.com :2pm
#   一口气带你认识…… http://xhslink.cn/o/AahIzgf95oX 复制后打开【小红书】查看笔记！
# 规则：找第一个 http(s):// 开头的网址；没有的话，找认识的网站名（比如 youtu.be/xxx）补上 https://。
# 网址到空格、中文、引号为止，末尾的标点去掉。
#----------------------------------------------------------------------
my $KNOWN_HOSTS = qr/(?:youtube\.com|youtu\.be|douyin\.com|iesdouyin\.com|xhslink\.com|xhslink\.cn|xiaohongshu\.com|b23\.tv|bilibili\.com|tiktok\.com|x\.com|twitter\.com|instagram\.com)/i;
sub extract_link {
  my ($t) = @_;
  $t = '' unless defined $t;
  my $u;
  if ($t =~ m{(https?://[^\s<>"'`\x80-\xff]+)}i) {
    $u = $1;
  } elsif ($t =~ m{(?<![A-Za-z0-9.\-])((?:[A-Za-z0-9\-]+\.)*$KNOWN_HOSTS/[^\s<>"'`\x80-\xff]*)}) {
    $u = "https://$1";
  } else {
    return '';
  }
  $u =~ s/[.,;:!?)\]}>]+$//;
  return $u;
}

# 去掉没用的追踪参数，把链接整理成平台认的样子。
sub clean_link {
  my ($u) = @_;
  my $plat = platform_of($u);
  # 分享文字里常是 http://，有些机房不让连 80 端口，统一改成 https://。
  $u =~ s{^http://}{https://}i if $plat ne 'other';
  if ($plat eq 'bili' && $u =~ m{bilibili\.com/(?:s/)?video/(BV[0-9A-Za-z]{10}|av\d+)}i) {
    my $id = $1;
    my ($pn) = $u =~ /[?&]p=(\d+)/;
    return "https://www.bilibili.com/video/$id/" . ($pn && $pn > 1 ? "?p=$pn" : '');
  }
  if ($plat eq 'x' || $plat eq 'ig' || $plat eq 'tiktok') {
    $u =~ s/[?#].*$//;
    $u =~ s{(/status/\d+)/(?:photo|video)/\d+/?$}{$1} if $plat eq 'x';
  }
  return $u;
}

sub job_dir   { return "$JOBS/$_[0]"; }
sub valid_id  { return defined $_[0] && $_[0] =~ /^[0-9a-f]{6,40}$/; }
sub job_meta  { return kv_read(job_dir($_[0]) . '/meta'); }
sub job_stat  { return kv_read(job_dir($_[0]) . '/status'); }
sub set_stat  { my ($id, %h) = @_; kv_update(job_dir($id) . '/status', %h, updated => time); }

sub list_jobs {
  opendir(my $dh, $JOBS) or return ();
  my @ids = grep { valid_id($_) && -d "$JOBS/$_" } readdir $dh;
  closedir $dh;
  return sort { $a cmp $b } @ids;
}

# 浏览器拿走的几段合在一起，看看有没有把整个文件都拿全。
sub delivered_bytes {
  my ($id, $size) = @_;
  my $d = slurp(job_dir($id) . '/sent') || '';
  my @r;
  for my $l (split /\n/, $d) {
    my ($s, $e) = split / /, $l;
    next unless defined $e && $s =~ /^\d+$/ && $e =~ /^\d+$/ && $e >= $s;
    push @r, [$s, $e];
  }
  @r = sort { $a->[0] <=> $b->[0] } @r;
  my ($total, $cs, $ce) = (0, -1, -2);
  for my $x (@r) {
    if ($x->[0] > $ce + 1) {
      $total += $ce - $cs + 1 if $ce >= $cs && $cs >= 0;
      ($cs, $ce) = @$x;
    } elsif ($x->[1] > $ce) {
      $ce = $x->[1];
    }
  }
  $total += $ce - $cs + 1 if $cs >= 0 && $ce >= $cs;
  return $total;
}

sub active_transfers {
  my ($id) = @_;
  my $dir = job_dir($id);
  opendir(my $dh, $dir) or return 0;
  my @a = grep { /^active\.\d+$/ } readdir $dh;
  closedir $dh;
  my $n = 0;
  for my $f (@a) {
    my ($pid) = $f =~ /(\d+)$/;
    if (kill(0, $pid)) { $n++; } else { unlink "$dir/$f"; }
  }
  return $n;
}

sub media_path {
  my ($id) = @_;
  my $st = job_stat($id);
  my $f = $st->{file};
  return undef unless defined $f && length $f && $f !~ m{/} && $f ne '.' && $f ne '..';
  my $p = job_dir($id) . "/$f";
  return -f $p ? $p : undef;
}

sub job_view {
  my ($id) = @_;
  my $m  = job_meta($id);
  my $st = job_stat($id);
  my $state = $st->{state} || 'queued';
  my $path = media_path($id);
  my $size = $st->{size} || 0;
  my $sent = ($state eq 'done' && $size) ? delivered_bytes($id, $size) : 0;
  my $line = $st->{line} || '';
  my $delivered = ($state eq 'done' && $size && $sent >= $size) ? 1 : 0;
  # 存到 Mac 以后，网页亮一下 ✅ 就收起来；万一网页没开着，15 秒后也不再显示。
  my $sent_at = $delivered ? ((stat(job_dir($id) . '/sent'))[9] || 0) : 0;
  my $hidden = $st->{dismissed} || ($delivered && time - $sent_at > 15) ? 1 : 0;
  if ($state eq 'queued') {
    $line = upgrading() ? '服务器正在升级，等一会儿会自动开始' : '排队中，前面的下完就轮到它';
  } elsif ($state eq 'done') {
    if ($delivered) {
      $line = '✅ 已存到 Mac 的「下载」文件夹';
    } elsif (!$path) {
      $line = $st->{gone} || '已经传到你的 Mac，服务器上的文件已删除';
    } elsif ($sent > 0) {
      $line = sprintf('正在传到你的 Mac（%d%%）。看浏览器右上角的下载图标', int($sent * 100 / $size));
    } else {
      $line = '服务器已下好，正在交给浏览器保存到 Mac…';
    }
  }
  return {
    id      => $id,
    url     => $m->{url},
    plat    => plat_name($m->{plat} || platform_of($m->{url})),
    quality => $QUALITY{ $m->{q} || 'mac' } || '',
    note    => $st->{note} || '',
    hidden  => $hidden,
    q       => $m->{q} || 'mac',
    title   => $st->{title} || '',
    state   => $state,
    line    => $line,
    pct     => num($st->{pct} || 0),
    file    => $st->{file} || '',
    size    => human_size($size),
    has_file => bool($path),
    delivered => bool($delivered),
    error   => $st->{error} || '',
    hint    => $st->{hint} || '',
    created => num($m->{created} || 0),
  };
}

#----------------------------------------------------------------------
# 收到一个新链接。先检查像不像视频链接，再排进队里。
#----------------------------------------------------------------------
sub check_url {
  my ($u) = @_;
  $u = '' unless defined $u;
  $u =~ s/^\s+|\s+$//g;
  return (undef, '先把视频链接（或 App 里复制的整段分享文字）粘贴到框里。') unless length $u;
  my $raw = $u;
  $u = extract_link($u);
  return (undef, '这不像网址。请从浏览器地址栏，或 App 的「分享 → 复制链接」里复制，应该带 https:// 开头的网址。')
    unless length $u && $u =~ m{^https?://[^\s/]+\.[^\s/]+\S*$}i && length($u) < 2000;
  if ($u =~ m{^https?://([^/]*\.)?youtube\.com/(playlist|feed|channel|c/|@)}i && $u !~ /[?&]v=/) {
    return (undef, '这是播放列表或频道的链接。一次只能贴一个视频：点进某个视频，再复制它的链接。');
  }
  my $plat = platform_of($u);
  if ($plat eq 'bili' && $u =~ m{bilibili\.com/(bangumi|cheese)/}i) {
    return (undef, '这是 B 站番剧/课程的链接，一般要大会员或购买，下不了。普通视频（网址里有 BV 号）可以。');
  }
  if ($plat eq 'douyin' && $u =~ m{douyin\.com/(user|search|live)}i) {
    return (undef, '这是抖音主页/搜索/直播的链接。请点进某一条作品，再「分享 → 复制链接」。');
  }
  if ($plat eq 'xhs' && $u =~ m{xiaohongshu\.com/user/profile}i) {
    return (undef, '这是小红书个人主页的链接。请点进某一篇笔记，再「分享 → 复制链接」。');
  }
  return (clean_link($u), '');
}

# 安装脚本升级时会挂一块牌子 $STATE/upgrading（里面是安装脚本的进程号）。
# 牌子在、那个进程也还活着，就先不开始新任务，也不做每天的 yt-dlp 更新：
# 正在下的照常下完，安装脚本等它下完才重启。新贴的链接照收，排着队，重启后自动开始。
# 安装脚本早就退出了（进程号不在了）或者牌子挂了 3 小时以上，就当没有这块牌子。
sub upgrading {
  my $f = "$STATE/upgrading";
  my @s = stat($f) or return 0;
  my $pid = ((slurp($f) || '') =~ /(\d+)/) ? $1 : 0;
  return 0 unless $pid && time - $s[9] < 3 * 3600;
  return (kill(0, $pid) || $!{EPERM}) ? 1 : 0;
}

sub add_job {
  my ($u, $q) = @_;
  my ($url, $why) = check_url($u);
  return (undef, $why) unless $url;
  $q = 'mac' unless defined $q && $QUALITY{$q};
  my $waiting = grep { my $s = job_stat($_)->{state} || 'queued'; $s eq 'queued' || $s eq 'running' } list_jobs();
  return (undef, '排队的视频已经有 10 个了，等前面的下完再贴。') if $waiting >= 10;
  # 编号 = 时间 + 顺序号 + 一点随机数。按编号排序就是贴链接的先后顺序。
  my $seq = with_lock('seq', sub {
    my $n = (slurp("$STATE/seq") || 0) + 1;
    $n = 1 if $n > 99999;
    spit("$STATE/seq", "$n\n");
    return $n;
  });
  my $id = strftime('%Y%m%d%H%M%S', localtime) . sprintf('%05d', $seq) . rand_hex(2);
  make_path(job_dir($id));
  my $plat = platform_of($url);
  kv_write(job_dir($id) . '/meta', { url => $url, q => $q, plat => $plat, created => time });
  kv_write(job_dir($id) . '/status', { state => 'queued', updated => time });
  logline("新任务 $id [$plat] $url ($q)");
  return ($id, '');
}

#----------------------------------------------------------------------
# 把文件发给浏览器。支持断点续传，中文文件名不会乱码。
#----------------------------------------------------------------------
my %MIME = (mp4 => 'video/mp4', m4a => 'audio/mp4', mp3 => 'audio/mpeg', webm => 'video/webm',
  mkv => 'video/x-matroska', opus => 'audio/ogg', ogg => 'audio/ogg', mov => 'video/quicktime');

sub serve_file {
  my ($c, $r, $id) = @_;
  my $path = media_path($id);
  unless ($path) {
    return respond($c, $r, 404, 'text/html; charset=utf-8',
      page_simple('文件已经不在服务器上了', '这个视频已经传给浏览器，或者放太久被自动删掉了。回到首页重新贴一次链接就行。'));
  }
  open(my $fh, '<', $path) or return respond($c, $r, 404, 'text/plain; charset=utf-8', "not found\n");
  binmode $fh;
  my @s = stat($fh);
  my ($size, $mtime) = ($s[7], $s[9]);
  my $etag = sprintf('"%x-%x"', $size, $mtime);
  my $lm = http_date($mtime);
  my ($start, $end, $partial) = (0, $size - 1, 0);
  my $range = $r->{headers}{range};
  my $ifr = $r->{headers}{'if-range'};
  if (defined $range && (!defined $ifr || $ifr eq $etag || $ifr eq $lm)) {
    if ($range =~ /^bytes=(\d*)-(\d*)$/ && (length $1 || length $2)) {
      my ($a, $b) = ($1, $2);
      if (length $a) {
        $start = $a + 0;
        $end = length $b ? $b + 0 : $size - 1;
        $end = $size - 1 if $end > $size - 1;
      } else {
        my $n = $b + 0;
        $start = $n >= $size ? 0 : $size - $n;
        $end = $size - 1;
      }
      if ($start > $end || $start >= $size) {
        return respond($c, $r, 416, 'text/plain; charset=utf-8', '', { 'Content-Range' => "bytes */$size" });
      }
      $partial = 1;
    }
  }
  my $name = (split m{/}, $path)[-1];
  my ($ext) = $name =~ /\.([A-Za-z0-9]+)$/;
  $ext = lc($ext || '');
  my $ascii = $name;
  $ascii =~ s/[^\x20-\x7e]/_/g;
  $ascii =~ s/["\\;%]/_/g;
  $ascii =~ s/_{2,}/_/g;
  $ascii = "video.$ext" if $ascii =~ /^[_ .]*(\.[A-Za-z0-9]+)?$/;
  my $len = $end - $start + 1;
  my %h = (
    'Content-Type' => $MIME{$ext} || 'application/octet-stream',
    'Content-Length' => $len,
    'Content-Disposition' => "attachment; filename=\"$ascii\"; filename*=UTF-8''" . pct_encode($name),
    'Accept-Ranges' => 'bytes',
    'ETag' => $etag,
    'Last-Modified' => $lm,
    'Cache-Control' => 'private, no-transform',
  );
  $h{'Content-Range'} = "bytes $start-$end/$size" if $partial;
  return unless write_all($c, head_text($partial ? 206 : 200, \%h));
  return if $r->{method} eq 'HEAD';
  # 记下“有人正在拿这个文件”。正在传的时候不会被清理删掉。
  my $mark = job_dir($id) . "/active.$$";
  if (open(my $mk, '>', $mark)) { close $mk; }
  logline("开始发送 $id 字节 $start-$end/$size 给 $r->{ip}");
  sysseek($fh, $start, 0);
  my $sel = IO::Select->new($c);
  my $done = 0;
  while ($done < $len) {
    my $want = $len - $done;
    $want = 262144 if $want > 262144;
    my $buf;
    my $got = sysread($fh, $buf, $want);
    last unless $got;
    my $off = 0;
    while ($off < $got) {
      last unless $sel->can_write(300);
      my $n = syswrite($c, $buf, $got - $off, $off);
      last unless defined $n && $n > 0;
      $off += $n;
    }
    $done += $off;
    last if $off < $got;
  }
  close $fh;
  if ($done > 0) {
    if (sysopen(my $sf, job_dir($id) . '/sent', O_WRONLY | O_CREAT | O_APPEND)) {
      syswrite($sf, sprintf("%d %d\n", $start, $start + $done - 1));
      close $sf;
    }
  }
  unlink $mark;
  logline(sprintf('发送结束 %s 发出 %s / %s', $id, $done, $len));
}

#----------------------------------------------------------------------
# cookies：网页上贴进来的 cookies.txt。先检查格式，再存成只有 root 能读的文件。
#----------------------------------------------------------------------
#----------------------------------------------------------------------
# cookies：所有平台放在同一个 cookies.txt 里（yt-dlp 会自己挑对应网站的那几行）。
# 你可以分几次上传：这次上传了哪些平台，就只替换这些平台的旧 cookies，别的平台的不动。
#----------------------------------------------------------------------
sub cookie_rows {
  my ($text) = @_;
  my @rows;
  for my $l (split /\n/, $text) {
    next if $l =~ /^#(?!HttpOnly_)/i || $l !~ /\S/;
    my @f = split /\t/, $l;
    next unless @f >= 7;
    push @rows, [cookie_plat($f[0]), $l];
  }
  return @rows;
}

# 现在存着哪些平台的 cookies：{ 平台 => 行数 }
sub cookie_plats {
  my $d = slurp($C{cookies});
  my %n;
  return \%n unless defined $d;
  $d =~ s/\r\n?/\n/g;
  $n{ $_->[0] }++ for grep { $_->[0] ne '' } cookie_rows($d);
  return \%n;
}

sub has_cookies { my ($plat) = @_; return cookie_plats()->{ $plat || 'youtube' } ? 1 : 0; }

sub cookies_bad_file { my ($plat) = @_; return ($plat || 'youtube') eq 'youtube' ? "$STATE/cookies-bad" : "$STATE/cookies-bad-$plat"; }

sub write_cookie_rows {
  my (@rows) = @_;
  my $f = $C{cookies};
  unless (@rows) { unlink $f; return 1; }
  my $text = "# Netscape HTTP Cookie File\n# ytdlp-web 保存的 cookies，可以有好几个平台的\n" . join('', map { "$_->[1]\n" } @rows);
  my $old = umask 077;
  my $okw = spit($f, $text);
  umask $old;
  return 0 unless $okw;
  chmod 0600, $f;
  return 1;
}

sub save_cookies {
  my ($text) = @_;
  $text = '' unless defined $text;
  $text =~ s/\r\n?/\n/g;
  $text =~ s/^\xEF\xBB\xBF//;
  return ('框里是空的。先选择文件，或者把 cookies.txt 的内容粘贴进来。') unless $text =~ /\S/;
  return ('这是 JSON 格式。请在扩展里选「Netscape」或「cookies.txt」格式再导出一次。') if $text =~ /^\s*[\[{]/;
  my @new = cookie_rows($text);
  return ('看不懂这个文件。要的是扩展导出的 cookies.txt（每行用 Tab 分隔的那种）。') unless @new;
  my %got = map { $_->[0] => 1 } grep { $_->[0] ne '' } @new;
  return ('文件里没有认得出的网站的 cookies。支持：' . join('、', map { $_->{name} } @PLATFORMS)
    . '。请在那个网站的页面上点扩展导出。') unless %got;
  my $d = slurp($C{cookies});
  $d = '' unless defined $d;
  $d =~ s/\r\n?/\n/g;
  my @keep = grep { $_->[0] ne '' && !$got{ $_->[0] } } cookie_rows($d);
  return ('保存失败，服务器上写不了文件。') unless write_cookie_rows(@keep, grep { $_->[0] ne '' } @new);
  unlink cookies_bad_file($_) for keys %got;
  my @names = map { $_->{name} } grep { $got{ $_->{key} } } @PLATFORMS;
  logline('收到新的 cookies：' . join(' ', sort keys %got));
  return ('', \@names);
}

# 删掉某个平台的 cookies；不说平台就全删。
sub delete_cookies {
  my ($plat) = @_;
  if (!$plat || !$PLAT{$plat}) {
    unlink $C{cookies};
    unlink cookies_bad_file($_->{key}) for @PLATFORMS;
    logline('cookies 已全部删除');
    return;
  }
  my $d = slurp($C{cookies});
  $d = '' unless defined $d;
  $d =~ s/\r\n?/\n/g;
  write_cookie_rows(grep { $_->[0] ne '' && $_->[0] ne $plat } cookie_rows($d));
  unlink cookies_bad_file($plat);
  logline("$plat 的 cookies 已删除");
}

#----------------------------------------------------------------------
# 路由：浏览器要什么，就交给对应的那一段。
#----------------------------------------------------------------------
sub handle {
  my ($c) = @_;
  my $r = read_request($c);
  return unless $r;
  my $p = $r->{path};
  my $m = $r->{method};
  return respond($c, $r, 413, 'text/plain; charset=utf-8', "too big\n") if $r->{too_big};

  if ($p eq '/health') {
    return respond($c, $r, 200, 'text/plain; charset=utf-8', "ytdlp-web ok $VERSION\n");
  }
  if ($p eq '/login' && $m eq 'POST') {
    if (login_blocked($r->{ip})) {
      return respond($c, $r, 429, 'text/html; charset=utf-8', page_login('密码错了太多次。请 10 分钟后再试。'));
    }
    my $f = parse_form($r->{body});
    if (password_ok($f->{user}, $f->{pass})) {
      my $tok = session_add();
      logline("登录成功 $r->{ip}");
      return redirect($c, $r, '/', { 'Set-Cookie' => "ytw=$tok; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax" });
    }
    login_failed($r->{ip});
    logline("登录失败 $r->{ip}");
    return respond($c, $r, 401, 'text/html; charset=utf-8', page_login('名字或密码不对。忘了密码：在 VPS 上输入 ytdlp-web --status 查看。'));
  }
  if ($p eq '/logout') {
    session_del(cookie_token($r));
    return redirect($c, $r, '/', { 'Set-Cookie' => 'ytw=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax' });
  }
  unless (session_ok($r)) {
    return respond_json($c, $r, 401, { error => '请先登录' }) if $p =~ m{^/api/};
    return respond($c, $r, 200, 'text/html; charset=utf-8', page_login('')) if $p eq '/' || $p eq '/login';
    return redirect($c, $r, '/');
  }

  if ($p eq '/' || $p eq '/login') {
    return respond($c, $r, 200, 'text/html; charset=utf-8', page_app());
  }
  if ($p =~ m{^/dl/([0-9a-f]+)$} && ($m eq 'GET' || $m eq 'HEAD')) {
    my $id = $1;
    return respond($c, $r, 404, 'text/plain; charset=utf-8', "not found\n") unless valid_id($id);
    return serve_file($c, $r, $id);
  }
  if ($p eq '/api/jobs' && $m eq 'GET') {
    # 已经存到 Mac 的任务不再显示（网页会先亮一下 ✅ 再收起来）。
    my @v = grep { !$_->{hidden} } map { job_view($_) } reverse list_jobs();
    @v = @v[0 .. 29] if @v > 30;
    delete $_->{hidden} for @v;
    return respond_json($c, $r, 200, { jobs => \@v, info => server_info() });
  }
  # 改东西的请求必须带上网页自己加的暗号，别的网站骗不了你的浏览器来下单。
  if ($m eq 'POST' && $p =~ m{^/api/}) {
    return respond_json($c, $r, 403, { error => '请刷新网页再试一次' }) unless ($r->{headers}{'x-ytw'} || '') eq '1';
    my $f = parse_form($r->{body});
    if ($p eq '/api/add') {
      my ($id, $why) = add_job($f->{url}, $f->{q});
      my %ok = (ok => bool(1), id => $id);
      $ok{note} = '收到了。服务器正在升级，等正在下的视频下完会自动重启，这个会在重启后自动开始下载，不用管。' if $id && upgrading();
      return respond_json($c, $r, 200, $id ? \%ok : { error => $why });
    }
    if ($p eq '/api/delete') {
      my $id = $f->{id};
      return respond_json($c, $r, 404, { error => '没有这个任务' }) unless valid_id($id) && -d job_dir($id);
      my $st = job_stat($id)->{state} || 'queued';
      if ($st eq 'running') {
        if (open(my $cf, '>', job_dir($id) . '/cancel')) { close $cf; }
      } else {
        remove_tree(job_dir($id));
      }
      logline("删除任务 $id");
      return respond_json($c, $r, 200, { ok => bool(1) });
    }
    if ($p eq '/api/dismiss') {
      # 网页说「这个已经存到 Mac 了，收起来吧」。只收已经送达的；文件还是按原来的规则过一会儿再删。
      my $id = $f->{id};
      return respond_json($c, $r, 404, { error => '没有这个任务' }) unless valid_id($id) && -d job_dir($id);
      my $st = job_stat($id);
      return respond_json($c, $r, 200, { error => '还没传完' })
        unless ($st->{state} || '') eq 'done' && ($st->{delivered} || ($st->{size} && delivered_bytes($id, $st->{size}) >= $st->{size}));
      set_stat($id, dismissed => 1);
      return respond_json($c, $r, 200, { ok => bool(1) });
    }
    if ($p eq '/api/cookies') {
      my ($why, $names) = save_cookies($f->{text});
      return respond_json($c, $r, 200, $why ? { error => $why } : { ok => bool(1), sites => $names });
    }
    if ($p eq '/api/cookies/delete') {
      delete_cookies($f->{plat});
      return respond_json($c, $r, 200, { ok => bool(1) });
    }
    if ($p eq '/api/update') {
      unlink "$STATE/last-update";
      return respond_json($c, $r, 200, { ok => bool(1) });
    }
  }
  return respond($c, $r, 404, 'text/plain; charset=utf-8', "not found\n");
}

sub server_info {
  my $st = kv_read("$STATE/info");
  my $sticky = kv_read("$STATE/sticky");
  my %names = map { $_->{key} => $_->{label} } all_methods('youtube');
  my $has_ck = -s $C{cookies} ? 1 : 0;
  my @ms = map { $_->{label} } grep { $_->{ok} } all_methods('youtube');
  my $cp = cookie_plats();
  my @sites = map { { key => $_->{key}, name => $_->{name}, bad => bool(-e cookies_bad_file($_->{key})) } }
    grep { $cp->{ $_->{key} } } @PLATFORMS;
  return {
    ytdlp      => $st->{ytdlp_version} || '',
    updated    => $st->{last_update_text} || '',
    method     => ($sticky->{key} && $names{ $sticky->{key} }) ? $names{ $sticky->{key} } : '',
    methods    => \@ms,
    cookies    => bool($has_ck),
    cookies_at => $has_ck ? strftime('%Y-%m-%d %H:%M', localtime((stat($C{cookies}))[9])) : '',
    cookies_bad => bool(grep { -e cookies_bad_file($_->{key}) } @PLATFORMS),
    cookie_sites => \@sites,
    plugins    => bool($C{plugins} && -d $C{plugins}),
    keep_hours => num($C{keep_hours}),
    grace_min  => num(int(($C{grace} + 59) / 60)),
    free       => disk_free_mb($DATA) >= 0 ? human_size(disk_free_mb($DATA) * 1048576) : '',
    version    => $VERSION,
    upgrading  => bool(upgrading()),
  };
}

#----------------------------------------------------------------------
# 被 YouTube 拦住时一个一个试的办法。前面的不用账号，最后才用你上传的 cookies。
# 上次成功的办法会先试（记 24 小时），省时间。
#----------------------------------------------------------------------
sub has_global_ipv6 {
  my $d = slurp('/proc/net/if_inet6') || '';
  for my $l (split /\n/, $d) {
    my @f = split /\s+/, $l;
    next unless @f >= 6;
    next unless $f[3] eq '00';
    next if $f[0] =~ /^(fe8|fe9|fea|feb|fc|fd)/i || $f[0] =~ /^0{31}1$/;
    return 1;
  }
  return 0;
}

sub pot_args {
  return () unless $C{pot} && -x $C{pot} && $C{pot_plugins} && -d $C{pot_plugins};
  return ('--plugin-dirs', $C{pot_plugins}, '--extractor-args', "youtubepot-bgutilcli:cli_path=$C{pot}");
}

sub all_methods {
  my ($plat) = @_;
  $plat ||= 'youtube';
  my @pot = pot_args();
  my $warp = ($C{wireproxy} && -x $C{wireproxy} && $C{warp_conf} && -s $C{warp_conf}) ? 1 : 0;
  my $v6 = has_global_ipv6();
  my $ck = has_cookies($plat);
  if ($plat eq 'youtube') {
    return (
      { key => 'direct',  label => '直接下载', ok => 1, args => [] },
      { key => 'clients', label => '换一种 YouTube 客户端', ok => 1,
        args => ['--extractor-args', 'youtube:player_client=android_vr,web_safari,tv_downgraded,web_embedded'] },
      { key => 'ipv6',    label => '改走 IPv6', ok => $v6, args => ['--force-ipv6'] },
      { key => 'pot',     label => '自动生成 PO 令牌', ok => (@pot ? 1 : 0),
        args => [@pot, '--extractor-args', 'youtube:player_client=default,mweb'] },
      { key => 'ipv4',    label => '改走 IPv4 + PO 令牌', ok => ($v6 && @pot ? 1 : 0),
        args => ['--force-ipv4', @pot, '--extractor-args', 'youtube:player_client=default,mweb'] },
      { key => 'warp',    label => '换 Cloudflare WARP 线路', ok => $warp, warp => 1,
        args => ['--proxy', "socks5://127.0.0.1:$C{warp_port}", @pot] },
      { key => 'cookies', label => '用你上传的 cookies', ok => $ck, cookies => 1,
        args => ['--cookies', $C{cookies}] },
    );
  }
  # 其他平台：先用 IPv6 再用 IPv4（机器没有 IPv6 就只走 IPv4），再换 WARP，最后才用 cookies。
  # helper 表示交给我们自己的插件（网址写成 ytweb:平台:链接）。
  my $plug = ($C{plugins} && -d $C{plugins}) ? 1 : 0;
  my %helper = (xhs => 'xhs', bili => 'bili', douyin => 'douyin');
  my $h = $helper{$plat} || '';
  my $how = $h ? '不登录的网页办法' : '直接下载';
  my @ip = $v6
    ? ({ ip => 'IPv6', args => ['--force-ipv6'] }, { ip => 'IPv4', args => ['--force-ipv4'] })
    : ({ ip => 'IPv4', args => [] });
  my @m;
  my $hok = $h ? $plug : 1;
  for my $x (@ip) {
    push @m, { key => lc("$x->{ip}"), label => "$how（$x->{ip}）", ip => $x->{ip}, ok => $hok, helper => $h, args => $x->{args} };
  }
  push @m, { key => 'warp', label => "$how（Cloudflare WARP 线路）", ip => 'WARP', ok => $warp && $hok, warp => 1, helper => $h,
    args => ['--proxy', "socks5://127.0.0.1:$C{warp_port}"] };
  push @m, { key => 'cookies', label => "用你上传的 cookies（$how）", ip => '默认', ok => $ck && $hok, cookies => 1, helper => $h,
    args => ['--cookies', $C{cookies}] };
  # 抖音、B站：插件不行时，再让 yt-dlp 自带的办法带着你的 cookies 试一次。
  push @m, { key => 'cookies2', label => '用你上传的 cookies（yt-dlp 自带办法）', ip => '默认', ok => $ck, cookies => 1, helper => '',
    args => ['--cookies', $C{cookies}] } if $h && $plat ne 'xhs';
  return @m;
}

# 推特那条没有视频时，改去拿图片。
sub image_methods {
  my ($plat) = @_;
  return () unless $C{plugins} && -d $C{plugins};
  my $v6 = has_global_ipv6();
  return (
    ($v6 ? ({ key => 'img6', label => '下载推文里的图片（IPv6）', ip => 'IPv6', ok => 1, helper => 'ximg', args => ['--force-ipv6'] }) : ()),
    { key => 'img4', label => '下载推文里的图片（IPv4）', ip => 'IPv4', ok => 1, helper => 'ximg', args => ($v6 ? ['--force-ipv4'] : []) },
  );
}

sub sticky_file { my ($plat) = @_; return ($plat || 'youtube') eq 'youtube' ? "$STATE/sticky" : "$STATE/sticky-$plat"; }

sub method_order {
  my ($plat) = @_;
  my @m = grep { $_->{ok} } all_methods($plat);
  my $s = kv_read(sticky_file($plat));
  if ($s->{key} && ($s->{at} || 0) > time - 86400) {
    my @first = grep { $_->{key} eq $s->{key} } @m;
    my @rest  = grep { $_->{key} ne $s->{key} } @m;
    @m = (@first, @rest);
  }
  return @m;
}

sub quality_args {
  my ($q, $plat) = @_;
  $plat ||= 'youtube';
  my $ff = ($C{ffmpeg} && -x $C{ffmpeg}) ? 1 : 0;
  if ($q eq 'm4a') {
    return $ff ? ('-f', 'ba[ext=m4a]/ba/b', '-x', '--audio-format', 'm4a') : ('-f', 'ba[ext=m4a]/ba');
  }
  if ($q eq 'mp3') {
    return ('-f', 'ba/b', '-x', '--audio-format', 'mp3', '--audio-quality', '2');
  }
  my $fmt = $ff ? 'bv*+ba/b' : 'b';
  return ('-f', $fmt, '--merge-output-format', 'mp4/mkv') if $q eq 'best';
  if ($plat ne 'youtube') {
    # 别的平台：先找现成的 H.264（avc1），画面和声音分开的就合成 mp4（不转码，很快）；
    # 实在没有 H.264，才下别的格式，下好后再转码。没标格式的 mp4（比如 Instagram 的）一般也是 H.264。
    $fmt = $ff ? 'bv*[vcodec^=avc]+ba[acodec^=mp4a]/bv*[vcodec^=avc]+ba/b[vcodec^=avc]/b[ext=mp4]/bv*+ba/b'
               : 'b[vcodec^=avc]/b[ext=mp4]/b';
  }
  return ('-f', $fmt, '-S', 'vcodec:h264,res:720,acodec:aac', '--merge-output-format', 'mp4') if $q eq 'p720';
  return ('-f', $fmt, '-S', 'vcodec:h264,res,acodec:aac', '--merge-output-format', 'mp4');
}

sub base_args {
  my ($dir) = @_;
  my @a = (
    '--ignore-config', '--no-playlist', '--no-mtime', '--newline', '--progress', '--color', 'never',
    '--no-simulate', '--match-filter', '!is_live',
    '--progress-template', 'download:PROG %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s',
    '--progress-template', 'postprocess:POST %(progress.postprocessor)s',
    '--print', 'video:TITLE %(title)s',
    '--print', 'after_move:FILE %(filepath)s',
    '--paths', "home:$dir", '--paths', "temp:$dir",
    # 一条帖子里有好几个文件（多图、多段视频）时，文件名后面加 1 2 3，免得互相覆盖。单个视频的名字和以前一样。
    '-o', '%(title).150B%(playlist_index& {}|)s.%(ext)s',
    '--retries', '5', '--fragment-retries', '5', '--socket-timeout', '30',
    '--cache-dir', "$DATA/cache",
  );
  push @a, '--js-runtimes', $C{js} if $C{js};
  push @a, '--ffmpeg-location', $C{ffmpeg} if $C{ffmpeg} && -x $C{ffmpeg};
  return @a;
}

#----------------------------------------------------------------------
# 看 yt-dlp 的英文报错，换成大白话。返回：种类、给你看的话、提示。
#   blocked      被拦了，换下一种办法
#   need_cookies 一定要登录才能看（年龄限制、会员）
#   cookies_bad  cookies 过期了
#   fatal        换办法也没用（链接错、视频删了、硬盘满）
#----------------------------------------------------------------------
sub classify_base {
  my ($out, $sig) = @_;
  my $t = lc($out || '');
  my @err = grep { /^error:/i } split /\n/, ($out || '');
  my $e = lc(join("\n", @err) || $t);
  return ('fatal', '服务器内存不够，下载程序被系统杀掉了。换一个小一点的画质（比如 720p）再试，或者给 VPS 加内存。', '')
    if $sig && $sig == 9;
  return ('fatal', '服务器硬盘满了。等一会儿让旧文件自动删掉，或者清一清 VPS 的硬盘。', '') if $t =~ /no space left/;
  return ('cookies_bad', '你上传的 cookies 已经失效了（过期或者 YouTube 让它下线了）。请按下面的步骤重新导出一份再上传。', 'cookies')
    if $e =~ /cookies are no longer valid|cookies (have|has) (expired|been rotated)/;
  return ('need_cookies', '这个视频有年龄限制，YouTube 要求登录才能看。请上传一个已满 18 岁的 YouTube 小号的 cookies。', 'cookies')
    if $e =~ /confirm your age|age[- ]restricted|inappropriate for some users/;
  return ('need_cookies', '这是频道会员专属视频，要用已经加入会员的账号的 cookies 才能下。', 'cookies')
    if $e =~ /members[- ]only|join this channel/;
  return ('fatal', '这是私密视频，只有上传者自己能看，下不了。', '') if $e =~ /private video/;
  return ('fatal', '这是正在直播（或还没开始）的视频，暂时下不了。等直播结束有回放了再试。', '')
    if $e =~ /live event will begin|premieres in|is_live|is a live/ || ($t =~ /does not pass filter/ && $t =~ /is_live/);
  return ('fatal', '这个链接下载程序认不出来。请确认是视频页面的链接（例如 https://www.youtube.com/watch?v=...）。', '')
    if $e =~ /unsupported url|is not a valid url|no video formats found|incomplete youtube id/;
  return ('fatal', '服务器上的 ffmpeg 不能用，合并不了画面和声音。在 VPS 上运行 ytdlp-web 回车更新一次。', '')
    if $e =~ /ffmpeg.*not (installed|found)|ffprobe.*not found/;
  return ('blocked', 'YouTube 认为这台服务器是机器人，要求登录（Sign in to confirm you’re not a bot）。', 'cookies')
    if $e =~ /not a bot|sign in to confirm/;
  return ('blocked', '这台服务器下载太频繁，被 YouTube 暂时限制了。', 'cookies')
    if $e =~ /http error 429|too many requests|try again later|rate[- ]limit/;
  return ('blocked', 'YouTube 拒绝了这台服务器的下载请求（403）。', 'cookies') if $e =~ /http error 403|403: forbidden/;
  return ('blocked', '这个视频在服务器所在的国家/地区看不了。', '')
    if $e =~ /not available in your country|not made this video available in your country|geo.?restrict/;
  return ('blocked', 'YouTube 的视频暗号没解开（要用 JavaScript 程序算）。', '')
    if $e =~ /javascript runtime|challenge solving failed|signature|nsig|n challenge/;
  return ('blocked', '没拿到可以下载的画质，多半是被 YouTube 限制了。', 'cookies')
    if $e =~ /requested format is not available|only images are available|page needs to be reloaded|failed to extract|unable to extract|precondition/;
  return ('fatal', '这个视频不存在，或者已经被删除。请在浏览器里确认一下能不能打开。', '')
    if $e =~ /video unavailable|has been removed|does not exist|this video is no longer available/;
  return ('blocked', '服务器连不上 YouTube（网络不通或超时）。', '')
    if $e =~ /timed out|connection (reset|refused)|network is unreachable|name or service not known|temporary failure in name resolution|unable to connect to proxy|eof occurred|ssl: |ssl error|certificate verify/;
  my $raw = $err[-1] || (grep { /\S/ } split /\n/, ($out || ''))[-1] || '没有输出';
  $raw =~ s/^ERROR:\s*//i;
  $raw = substr($raw, 0, 300);
  return ('blocked', "下载失败。原始报错：$raw", '');
}

# 先看各平台自己的报错（还有我们插件的 YTWEB_ 暗号），认不出来再交给上面 YouTube 那一套。
#   no_video  推特：这条推文没有视频（多半是图片帖），改去下图片
sub classify {
  my ($out, $sig, $plat) = @_;
  $plat ||= 'youtube';
  return classify_base($out, $sig) if $plat eq 'youtube';
  my $name = plat_name($plat);
  my $t = lc($out || '');
  my @err = grep { /^error:/i } split /\n/, ($out || '');
  my $e = lc(join("\n", @err) || $t);
  return classify_base($out, $sig) if ($sig && $sig == 9) || $t =~ /no space left/;
  return ('fatal', '这条没有视频也没有图片（可能是纯文字），没有东西可以下载。', '') if $e =~ /ytweb_no_media/;
  return ('fatal', "这条内容不存在、已经被删除，或者被作者设成了私密。请在手机上确认一下还能不能打开。", '') if $e =~ /ytweb_gone/;
  return ('fatal', "看不懂这个$name链接。请在 App 里点「分享 → 复制链接」，把整段文字贴过来。", '') if $e =~ /ytweb_bad_link/;
  return ('cookies_bad', "你上传的 $name cookies 已经失效了。请按下面的步骤重新导出一份再上传。", 'cookies')
    if $e =~ /cookies are no longer valid|cookies (have|has) (expired|been rotated)/;
  if ($plat eq 'x') {
    return ('no_video', '这条推文里没有视频。', '') if $e =~ /no video could be found|no video formats found|there.?s no video in this tweet/;
    return ('need_cookies', '这条推文被标成了敏感内容，推特要求登录才能看。', 'cookies') if $e =~ /nsfw|sensitive|age.?restricted|log ?in to view/;
    return ('fatal', '这条推文不存在、已被删除，或者账号设成了不公开。', '') if $e =~ /suspended|protected|tweet unavailable|does not exist|status not found|http error 404/;
  }
  if ($plat eq 'ig') {
    return ('fatal', '这条 Instagram 只有图片，没有视频。现在只支持下 Instagram 的视频；图片请在手机上保存。', '')
      if $e =~ /no video formats found|there is no video in this post|only images/;
    return ('blocked', 'Instagram 不让这台服务器在不登录的情况下看这条（要求登录或请求太频繁）。', 'cookies')
      if $e =~ /login required|rate.?limit|requested content is not available|main webpage is locked|log ?in|cookies/;
  }
  if ($plat eq 'tiktok') {
    return ('blocked', 'TikTok 拦住了这台服务器的 IP。', 'cookies') if $e =~ /ip address is blocked|status code 10204|unable to find video in feed|10222/;
    return ('fatal', '这条 TikTok 是私密的，或者已经被删除。', '') if $e =~ /private|status code 10216|video (is )?(not available|unavailable)/;
  }
  if ($plat eq 'douyin') {
    return ('blocked', '抖音不给海外服务器看这条（要「新鲜的 cookies」）。', 'cookies') if $e =~ /fresh cookies|ytweb_need_cookies/;
  }
  if ($plat eq 'bili') {
    return ('blocked', 'B 站的风控拦住了这台服务器（HTTP 412）。', 'cookies') if $e =~ /http error 412|precondition failed/;
    return ('need_cookies', '这个 B 站视频要登录（或者大会员）才能看。', 'cookies') if $e =~ /premium|大会员|login|ytweb_need_cookies.*vip/;
  }
  return ('blocked', "$name 不让海外服务器在不登录的情况下看这条。", 'cookies') if $e =~ /ytweb_need_cookies/;
  return ('fatal', "这个链接下载程序认不出来。请确认是单条视频/帖子的链接（在 App 里点「分享 → 复制链接」）。", '')
    if $e =~ /unsupported url|is not a valid url/;
  return ('fatal', "这条$name内容不存在或已被删除。", '') if $e =~ /http error 404|not found/ && $e !~ /ffmpeg|ffprobe/;
  my ($class, $msg, $hint) = classify_base($out, $sig);
  $msg =~ s/YouTube/$name/g;
  $msg =~ s/（例如 https:\/\/www\.youtube\.com\/watch\?v=\.\.\.）//;
  return ($class, $msg, $hint);
}

#----------------------------------------------------------------------
# 跑一次 yt-dlp。一边跑一边把进度写给网页看。
#----------------------------------------------------------------------
sub child_env {
  $ENV{TMPDIR} = "$DATA/tmp";
  $ENV{TMP} = $ENV{TEMP} = $ENV{TMPDIR};
  $ENV{HOME} = "$DATA/home";
  $ENV{XDG_CACHE_HOME} = "$DATA/cache";
  $ENV{LANG} = 'C.UTF-8';
  $ENV{LC_ALL} = 'C.UTF-8';
  $ENV{PYTHONIOENCODING} = 'utf-8';
  $ENV{PYTHONUTF8} = '1';
  $ENV{MALLOC_ARENA_MAX} = '2';
  $ENV{PATH} = '/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin';
}

sub run_cmd_capture {
  my ($timeout, @cmd) = @_;
  my $pid = open(my $out, '-|');
  return ('', -1) unless defined $pid;
  if ($pid == 0) {
    child_env();
    open(STDERR, '>&', \*STDOUT);
    exec { $cmd[0] } @cmd or POSIX::_exit(127);
  }
  my $buf = '';
  my $sel = IO::Select->new($out);
  my $end = time + $timeout;
  while (time < $end) {
    next unless $sel->can_read(1);
    my $n = sysread($out, $buf, 65536, length $buf);
    last unless $n;
  }
  kill 'KILL', $pid if time >= $end;
  close $out;
  return ($buf, $?);
}

sub port_open {
  my ($port) = @_;
  my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 2);
  return 0 unless $s;
  close $s;
  return 1;
}

# WARP 平时不开，省内存。要用的时候才把 wireproxy 叫起来，用完就关。
sub warp_start {
  return 0 if port_open($C{warp_port});
  my $pid = fork();
  return undef unless defined $pid;
  if ($pid == 0) {
    child_env();
    open(STDOUT, '>>', "$STATE/warp.log");
    open(STDERR, '>&', \*STDOUT);
    exec { $C{wireproxy} } $C{wireproxy}, '-c', $C{warp_conf} or POSIX::_exit(127);
  }
  for (1 .. 40) {
    return $pid if port_open($C{warp_port});
    last if waitpid($pid, WNOHANG) == $pid;
    select(undef, undef, undef, 0.25);
  }
  kill 'TERM', $pid;
  waitpid($pid, 0);
  return undef;
}

sub warp_stop {
  my ($pid) = @_;
  return unless $pid;
  kill 'TERM', $pid;
  for (1 .. 20) {
    return if waitpid($pid, WNOHANG) == $pid;
    select(undef, undef, undef, 0.1);
  }
  kill 'KILL', $pid;
  waitpid($pid, 0);
}

sub clean_media {
  my ($dir) = @_;
  opendir(my $dh, $dir) or return;
  for my $f (readdir $dh) {
    next if $f =~ /^(\.|\.\.|meta|status|log|cancel|sent)$/ || $f =~ /^active\./ || $f =~ /\.tmp\d+$/;
    my $p = "$dir/$f";
    if (-d $p) { remove_tree($p); } else { unlink $p; }
  }
  closedir $dh;
}

sub append_log {
  my ($dir, $text) = @_;
  my $f = "$dir/log";
  return if -s $f && -s $f > 2 * 1024 * 1024;
  if (open(my $fh, '>>', $f)) { print $fh $text; close $fh; }
}

# 网页服务要停的时候，正在跑的 yt-dlp 和 WARP 也一起停掉，不留孤儿进程。
our ($CUR_CHILD, $CUR_WARP) = (0, 0);
sub runner_stop {
  kill 'KILL', -$CUR_CHILD if $CUR_CHILD;
  kill 'TERM', $CUR_WARP if $CUR_WARP;
  POSIX::_exit(1);
}

sub run_ytdlp {
  my ($id, $meta, $m, $n, $total) = @_;
  my $dir = job_dir($id);
  my $plat = $meta->{plat} || platform_of($meta->{url});
  my $pname = plat_name($plat);
  # 交给插件的，网址写成 ytweb:平台:原链接；插件目录也要告诉 yt-dlp。
  my $url = $m->{helper} ? "ytweb:$m->{helper}:$meta->{url}" : $meta->{url};
  my @plug = ($m->{helper} && $C{plugins}) ? ('--plugin-dirs', $C{plugins}) : ();
  my @cmd = ($C{ytdlp}, base_args($dir), quality_args($meta->{q} || 'mac', $plat), @plug, @{ $m->{args} }, '--', $url);
  append_log($dir, "\n===== 第 $n 种办法：$m->{label}" . ($m->{ip} ? "，网络：$m->{ip}" : '') . " =====\n"
    . join(' ', map { /\s/ ? "'$_'" : $_ } @cmd) . "\n");
  my $warp_pid;
  if ($m->{warp}) {
    set_stat($id, line => "正在打开 Cloudflare WARP 线路…");
    $warp_pid = warp_start();
    unless (defined $warp_pid) {
      append_log($dir, "WARP 没打开，看 $STATE/warp.log\n");
      return (0, 'ERROR: unable to connect to proxy (WARP 没打开)', 0);
    }
  }
  my $pid = open(my $out, '-|');
  unless (defined $pid) {
    warp_stop($warp_pid);
    return (0, 'ERROR: fork failed', 0);
  }
  if ($pid == 0) {
    setpgrp(0, 0);
    child_env();
    chdir $dir;
    open(STDERR, '>&', \*STDOUT);
    eval { setpriority(0, 0, 10) };
    exec { $cmd[0] } @cmd or do { print "ERROR: 启动不了 $cmd[0]：$!\n"; POSIX::_exit(127); };
  }
  $CUR_CHILD = $pid;
  $CUR_WARP = $warp_pid;
  my $sel = IO::Select->new($out);
  my ($buf, $tail, $file, $part, $lastb, $lastw, $lastout) = ('', '', '', 1, -1, 0, time);
  my @files;
  my $src = $plat eq 'youtube' ? 'YouTube' : $pname;
  my $label = $total > 1 ? "（第 $n 种办法：$m->{label}）" : '';
  my $cancel = 0;
  while (1) {
    if (-e "$dir/cancel") { $cancel = 1; kill 'KILL', -$pid; last; }
    if (time - $lastout > 900) { append_log($dir, "15 分钟没有动静，强制停止\n"); kill 'KILL', -$pid; last; }
    next unless $sel->can_read(1);
    my $n2 = sysread($out, $buf, 65536, length $buf);
    last unless $n2;
    $lastout = time;
    while ($buf =~ s/^([^\n]*)\n//) {
      my $l = $1;
      $l =~ s/\r//g;
      if ($l =~ /^PROG (\S+) (\S+) (\S+) (\S+) (\S+)/) {
        my ($got, $tot, $est, $spd, $eta) = ($1, $2, $3, $4, $5);
        $tot = $est if $tot !~ /^\d/;
        next unless $got =~ /^\d/;
        $part++ if $lastb > 0 && $got + 0 < $lastb * 0.5 && $lastb > 1048576;
        $lastb = $got + 0;
        next if time - $lastw < 1;
        $lastw = time;
        my $pct = ($tot =~ /^\d/ && $tot > 0) ? int($got * 100 / $tot) : 0;
        my $line = "正在从 $src 下载到服务器" . (@files ? '（第 ' . (@files + 1) . ' 个文件）' : $part > 1 ? '（声音部分）' : '') . "：$pct%";
        $line .= '，' . human_size($spd) . '/秒' if $spd =~ /^\d/;
        $line .= '，还要 ' . human_secs($eta) if $eta =~ /^\d/;
        set_stat($id, line => $line . $label, pct => $pct);
        next;
      }
      if ($l =~ /^POST (\S+)/) {
        my $pp = $1;
        my $line = $pp =~ /Merger/ ? '正在把画面和声音合在一起…' : $pp =~ /ExtractAudio/ ? '正在转换成音频文件…' : '正在整理文件…';
        set_stat($id, line => $line, pct => 100) if time - $lastw >= 1;
        $lastw = time;
        next;
      }
      if ($l =~ /^TITLE (.*)$/) { set_stat($id, title => $1); next; }
      if ($l =~ /^FILE (.*)$/)  {
        $file = $1;
        my $b = (split m{/}, $1)[-1];
        push @files, $b unless grep { $_ eq $b } @files;
        $part = 1; $lastb = -1;
        next;
      }
      $tail .= "$l\n";
      append_log($dir, "$l\n");
      $tail = substr($tail, -20000) if length $tail > 40000;
    }
  }
  close $out;
  my $st = $?;
  waitpid($pid, 0);
  $CUR_CHILD = 0;
  $CUR_WARP = 0;
  warp_stop($warp_pid);
  return (0, 'CANCEL', 0) if $cancel;
  my $sig = $st & 127;
  my $code = $st >> 8;
  append_log($dir, "结束：退出码 $code" . ($sig ? "，信号 $sig" : '') . "\n");
  # 图文帖会有好几个文件（一张图一个），用换行连起来交回去。
  my @have = grep { -f "$dir/$_" && -s "$dir/$_" } @files;
  if (!$sig && @have && ($code == 0 || @have == @files)) {
    return (1, join("\n", @have), 0);
  }
  if ($code == 0 && !$sig && $tail =~ /does not pass filter/) {
    return (0, "ERROR: this is a live event (is_live)\n$tail", 0);
  }
  return (0, $tail, $sig);
}

# yt-dlp 每天自己更新一次。YouTube 经常改，旧版本很快就不能用。
# yt-dlp 自己的 -U 是先下好新文件再改名换上，正在跑的旧 yt-dlp 不受影响。
# 而且它只在「跑腿」进程里、没有视频在下的时候做（见主循环和 run_job 开头）。
sub update_ytdlp {
  my ($why) = @_;
  logline("检查 yt-dlp 更新（$why）");
  my ($out) = run_cmd_capture(600, $C{ytdlp}, '-U');
  my ($ver) = run_cmd_capture(120, $C{ytdlp}, '--version');
  $ver =~ s/\s+$//;
  $ver = (split /\n/, $ver)[-1] || '' if $ver;
  kv_update("$STATE/info", ytdlp_version => $ver, last_update => time,
    last_update_text => strftime('%Y-%m-%d %H:%M', localtime));
  $out =~ s/\s+$//;
  logline("yt-dlp 更新结果：" . ((split /\n/, $out)[-1] || ''));
}

sub update_due {
  my ($hours) = @_;
  my $last = kv_read("$STATE/info")->{last_update} || 0;
  return time - $last > $hours * 3600;
}

sub fail_job {
  my ($id, $msg, $hint) = @_;
  clean_media(job_dir($id));
  set_stat($id, state => 'error', error => $msg, hint => $hint || '', line => '', pct => 0);
  logline("任务 $id 失败：$msg");
}

#----------------------------------------------------------------------
# 图文帖有好几张图：打成一个 zip（不压缩，图片本来就压缩过了）。Mac 上双击就能解开。
# 只用 Perl 自带的东西，CRC32 自己算。
#----------------------------------------------------------------------
my @CRC_TABLE;
sub crc32_update {
  my ($crc, $data) = @_;
  unless (@CRC_TABLE) {
    for my $n (0 .. 255) {
      my $c = $n;
      for (1 .. 8) { $c = ($c & 1) ? (0xEDB88320 ^ ($c >> 1)) : ($c >> 1); }
      $CRC_TABLE[$n] = $c;
    }
  }
  $crc ^= 0xFFFFFFFF;
  $crc = $CRC_TABLE[($crc ^ $_) & 0xFF] ^ ($crc >> 8) for unpack('C*', $data);
  return $crc ^ 0xFFFFFFFF;
}

sub make_zip {
  my ($zip, $dir, @names) = @_;
  open(my $out, '>', $zip) or return 0;
  binmode $out;
  my ($off, $cd, $n) = (0, '', 0);
  my @t = localtime;
  my $dtime = ($t[2] << 11) | ($t[1] << 5) | int($t[0] / 2);
  my $ddate = (($t[5] - 80) << 9) | (($t[4] + 1) << 5) | $t[3];
  for my $name (@names) {
    open(my $in, '<', "$dir/$name") or next;
    binmode $in;
    my ($crc, $size, $data) = (0, 0, '');
    while (my $got = read($in, my $chunk, 65536)) { $crc = crc32_update($crc, $chunk); $size += $got; $data .= $chunk; }
    close $in;
    # 0x0800 = 文件名是 UTF-8（中文名不乱码）
    my $h = pack('VvvvvvVVVvv', 0x04034b50, 20, 0x0800, 0, $dtime, $ddate, $crc, $size, $size, length($name), 0);
    print $out $h, $name, $data;
    $cd .= pack('VvvvvvvVVVvvvvvVV', 0x02014b50, 20, 20, 0x0800, 0, $dtime, $ddate, $crc, $size, $size,
      length($name), 0, 0, 0, 0, 0, $off) . $name;
    $off += length($h) + length($name) + $size;
    $n++;
  }
  print $out $cd, pack('VvvvvVVv', 0x06054b50, 0, 0, $n, $n, length($cd), $off, 0);
  close $out or return 0;
  return $n;
}

#----------------------------------------------------------------------
# 确保视频 Mac 自带播放器能放：H.264 画面 + AAC 声音的 mp4。
#   本来就是：什么都不做
#   画面是 H.264/HEVC、只是声音或封装不对：只换声音/封装，几秒钟
#   画面是 VP9/AV1 等：转码成 H.264。1 核机器很慢，先按视频长度估个时间告诉你
# 只在选了「Mac 能直接播放」或「720p」时做。「最高画质」保留原格式。
#----------------------------------------------------------------------
sub ffprobe_path {
  return '' unless $C{ffmpeg} && -x $C{ffmpeg};
  (my $p = $C{ffmpeg}) =~ s{[^/]*$}{ffprobe};
  return -x $p ? $p : '';
}

sub probe_media {
  my ($path) = @_;
  my $fp = ffprobe_path() or return undef;
  my ($o) = run_cmd_capture(60, $fp, '-v', 'error', '-show_entries', 'stream=codec_type,codec_name,height:format=duration',
    '-of', 'compact=p=0:nk=0', $path);
  my %r = (v => '', a => '', h => 0, dur => 0);
  for my $l (split /\n/, $o || '') {
    my %f = map { split /=/, $_, 2 } grep { /=/ } split /\|/, $l;
    if (($f{codec_type} || '') eq 'video' && !$r{v} && ($f{codec_name} || '') !~ /^(mjpeg|png|bmp|gif|webp)$/) {
      $r{v} = $f{codec_name} || '';
      $r{h} = $f{height} || 0 if ($f{height} || '') =~ /^\d+$/;
    }
    $r{a} = $f{codec_name} || '' if ($f{codec_type} || '') eq 'audio' && !$r{a};
    $r{dur} = $f{duration} if defined $f{duration} && $f{duration} =~ /^[\d.]+$/;
  }
  return \%r;
}

# 按视频长度和清晰度估转码要几秒（1 核、veryfast 档）。
sub transcode_estimate {
  my ($dur, $h) = @_;
  my $f = $h <= 480 ? 0.6 : $h <= 720 ? 1.2 : $h <= 1080 ? 2.5 : 5;
  my $s = int(($dur || 60) * $f) + 10;
  return $s;
}

sub run_ffmpeg {
  my ($id, $dir, $dur, $line, @cmd) = @_;
  append_log($dir, "\n===== 转换格式 =====\n" . join(' ', map { /\s/ ? "'$_'" : $_ } @cmd) . "\n");
  my $pid = open(my $out, '-|');
  return 0 unless defined $pid;
  if ($pid == 0) {
    setpgrp(0, 0);
    child_env();
    chdir $dir;
    open(STDERR, '>>', "$dir/log");
    eval { setpriority(0, 0, 10) };
    exec { $cmd[0] } @cmd or POSIX::_exit(127);
  }
  $CUR_CHILD = $pid;
  my $sel = IO::Select->new($out);
  my ($buf, $lastw, $lastout, $cancel) = ('', 0, time, 0);
  while (1) {
    if (-e "$dir/cancel") { $cancel = 1; kill 'KILL', -$pid; last; }
    if (time - $lastout > 900) { kill 'KILL', -$pid; last; }
    next unless $sel->can_read(1);
    my $n = sysread($out, $buf, 65536, length $buf);
    last unless $n;
    $lastout = time;
    while ($buf =~ s/^([^\n]*)\n//) {
      my $l = $1;
      next unless $l =~ /^out_time_(?:us|ms)=(\d+)/;
      next if time - $lastw < 2 || !$dur;
      $lastw = time;
      my $pct = int($1 / 1e6 * 100 / $dur);
      $pct = 99 if $pct > 99;
      set_stat($id, line => "$line（$pct%）", pct => $pct);
    }
  }
  close $out;
  my $st = $?;
  waitpid($pid, 0);
  $CUR_CHILD = 0;
  return -1 if $cancel;
  return $st == 0 ? 1 : 0;
}

# 返回：(新文件名, 备注)。新文件名是 'CANCEL' 表示你取消了。
sub mac_fix {
  my ($id, $file, $q) = @_;
  my $dir = job_dir($id);
  return ($file, '') unless $q eq 'mac' || $q eq 'p720';
  return ($file, '') unless $file =~ /\.(mp4|mkv|webm|mov|flv|m4v)$/i;
  my $info = probe_media("$dir/$file") or return ($file, '');
  return ($file, '') unless $info->{v};
  my $v = lc $info->{v};
  my $a = lc $info->{a};
  my $aok = ($a eq '' || $a eq 'aac' || $a eq 'mp3');
  return ($file, '') if $v eq 'h264' && $aok && $file =~ /\.mp4$/i;
  (my $base = $file) =~ s/\.[^.]+$//;
  my $new = "$base.mac.mp4";
  my @in = ($C{ffmpeg}, '-hide_banner', '-nostdin', '-y', '-loglevel', 'error', '-progress', 'pipe:1', '-i', $file);
  my @audio = $aok && $a ne '' ? ('-c:a', 'copy') : ('-c:a', 'aac', '-b:a', '160k');
  my ($ok, $note);
  if ($v eq 'h264' || $v eq 'hevc') {
    # 画面不用动，只换声音/封装。HEVC 加上 hvc1 标记，QuickTime 才认。
    my @tag = $v eq 'hevc' ? ('-tag:v', 'hvc1') : ();
    set_stat($id, line => '正在整理成 Mac 能直接播放的 mp4…', pct => 100);
    $ok = run_ffmpeg($id, $dir, $info->{dur}, '正在整理成 Mac 能直接播放的 mp4',
      @in, '-map', '0:v:0', '-map', '0:a:0?', '-c:v', 'copy', @tag, @audio, '-movflags', '+faststart', $new);
  } else {
    my $est = transcode_estimate($info->{dur}, $info->{h});
    my $vname = uc($v eq 'vp9' ? 'VP9' : $v eq 'av1' ? 'AV1' : $v);
    my $line = "这个视频只有 $vname 格式，Mac 自带播放器放不了，正在转换成 H.264。这台机器转码比较慢，预计要 " . human_secs($est)
      . '（不想等可以取消，改选「最高画质」直接下原格式，用 IINA/VLC 播放）';
    set_stat($id, line => $line, pct => 0);
    logline("任务 $id 转码 $vname -> H.264，预计 ${est} 秒");
    my @scale = $info->{h} > 1080 ? ('-vf', 'scale=-2:1080') : ();
    $ok = run_ffmpeg($id, $dir, $info->{dur}, $line,
      @in, '-map', '0:v:0', '-map', '0:a:0?', @scale, '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23', '-pix_fmt', 'yuv420p',
      '-threads', '1', @audio, '-movflags', '+faststart', $new);
    $note = "原视频是 $vname，已转成 H.264";
  }
  return ('CANCEL', '') if $ok < 0;
  if ($ok && -s "$dir/$new") {
    unlink "$dir/$file";
    (my $final = $new) =~ s/\.mac\.mp4$/.mp4/;
    rename("$dir/$new", "$dir/$final") or $final = $new;
    return ($final, $note || '');
  }
  unlink "$dir/$new";
  append_log($dir, "转换失败，保留原文件\n");
  return ($file, '转换成 Mac 格式没成功，保留了原格式（用 IINA 或 VLC 能放）');
}

sub run_job {
  my ($id) = @_;
  $0 = 'ytdlp-web-job';
  my $dir = job_dir($id);
  my $meta = job_meta($id);
  my $plat = $meta->{plat} || platform_of($meta->{url});
  my $pname = plat_name($plat);
  set_stat($id, state => 'running', line => '准备中…', pct => 0, started => time);
  update_ytdlp('每天一次') if update_due($C{update_hours});
  my $free = disk_free_mb($DATA);
  if ($free >= 0 && $free < $C{min_free_mb}) {
    return fail_job($id, "服务器硬盘只剩 ${free}MB，放不下视频。等旧文件自动删掉，或者清一清 VPS 的硬盘。", '');
  }
  my @ms = method_order($plat);
  my $updated = 0;
  my ($last_msg, $last_hint, $used_cookies) = ('', '', 0);
  my $i = 0;
  my $src = $plat eq 'youtube' ? 'YouTube' : $pname;
  my @tried;
  while ($i < @ms) {
    my $m = $ms[$i];
    $i++;
    push @tried, $m->{ip} if $m->{ip} && !$m->{cookies} && !grep { $_ eq $m->{ip} } @tried;
    set_stat($id, line => @ms > 1 && $i > 1 ? "上一种办法不行，换第 $i 种办法：$m->{label}…" : "正在向 $src 要视频信息…", pct => 0);
    clean_media($dir);
    my ($ok, $res, $sig) = run_ytdlp($id, $meta, $m, $i, scalar @ms);
    if ($res eq 'CANCEL') {
      remove_tree($dir);
      logline("任务 $id 已取消");
      return;
    }
    if ($ok) {
      my @files = split /\n/, $res;
      my $note = '';
      my $q = $meta->{q} || 'mac';
      if (@files > 1) {
        # 一条帖子里有好几个文件（多图，或者 Instagram/推特一条里好几段视频）：视频先各自确保 Mac 能放，再一起打包。
        my ($nv, $ni) = (0, 0);
        for my $k (0 .. $#files) {
          if ($files[$k] =~ /\.(jpe?g|png|webp|gif|heic)$/i) { $ni++; next; }
          $nv++;
          my ($nf) = mac_fix($id, $files[$k], $q);
          if ($nf eq 'CANCEL') { remove_tree($dir); logline("任务 $id 已取消"); return; }
          $files[$k] = $nf;
        }
        set_stat($id, line => '正在把 ' . scalar(@files) . ' 个文件打成一个 zip…', pct => 100);
        my $title = job_stat($id)->{title} || 'images';
        $title =~ s{[/\\:*?"<>|\x00-\x1f]+}{_}g;
        $title =~ s/\s+\d+$//;
        $title = substr($title, 0, 120) || 'images';
        my $zip = "$title.zip";
        if (make_zip("$dir/$zip", $dir, @files)) {
          unlink "$dir/$_" for @files;
          $note = '这条里有 ' . join('、', ($ni ? "$ni 张图片" : ()), ($nv ? "$nv 段视频" : ())) . '，打包成了一个 zip，在 Mac 上双击就能解开';
          @files = ($zip);
        } else {
          return fail_job($id, '图片打包失败（服务器写不了文件）。', '');
        }
      } elsif ($files[0] =~ /\.(jpe?g|png|webp|gif|heic)$/i) {
        $note = '这条是图片，没有视频';
      } else {
        my ($nf, $n2) = mac_fix($id, $files[0], $q);
        if ($nf eq 'CANCEL') {
          remove_tree($dir);
          logline("任务 $id 已取消");
          return;
        }
        ($files[0], $note) = ($nf, $n2);
      }
      $res = $files[0];
      my $size = -s "$dir/$res";
      opendir(my $dh, $dir);
      for my $f (readdir $dh) {
        next if $f eq $res || $f =~ /^(\.|\.\.|meta|status|log|sent)$/ || $f =~ /^active\./;
        my $p = "$dir/$f";
        if (-d $p) { remove_tree($p); } else { unlink $p; }
      }
      closedir $dh;
      set_stat($id, state => 'done', file => $res, size => $size, done_at => time, line => '', pct => 100,
        method => $m->{label}, note => $note);
      kv_write(sticky_file($plat), { key => $m->{key}, at => time });
      unlink cookies_bad_file($plat) if $m->{cookies};
      logline("任务 $id 下好了（$m->{label}" . ($m->{ip} ? "，网络 $m->{ip}" : '') . "）：$res " . human_size($size));
      return;
    }
    my ($class, $msg, $hint) = classify($res, $sig, $plat);
    append_log($dir, "判断：$class / $msg\n");
    $used_cookies = 1 if $m->{cookies};
    ($last_msg, $last_hint) = ($msg, $hint);
    return fail_job($id, $msg, $hint) if $class eq 'fatal';
    if ($class eq 'no_video') {
      # 推特：没有视频，多半是图片帖。剩下的办法换成「下图片」。
      my @img = image_methods($plat);
      return fail_job($id, '这条推文里没有视频。下载图片要用到插件，在 VPS 上运行 ytdlp-web 回车更新一次就有了。', '') unless @img;
      next if $m->{helper} && $m->{helper} eq 'ximg';
      @ms = (@ms[0 .. $i - 1], @img);
      next;
    }
    if ($class eq 'cookies_bad') {
      if (open(my $bf, '>', cookies_bad_file($plat))) { close $bf; }
      return fail_job($id, $msg, 'cookies');
    }
    if ($class eq 'need_cookies') {
      my @ck = grep { $_->{cookies} } @ms[$i .. $#ms];
      return fail_job($id, $msg . " 请上传 $pname 的 cookies，方法在网页下面的「被拦住了？上传 cookies」里。", 'cookies') unless @ck;
      @ms = (@ms[0 .. $i - 1], @ck);
      next;
    }
    # 被拦了。先确认 yt-dlp 是最新的（新版本常常就修好了），再换下一种办法。
    if (!$updated && update_due(1)) {
      $updated = 1;
      set_stat($id, line => '先把 yt-dlp 更新到最新版本…');
      update_ytdlp("被 $src 拦了");
    }
  }
  my $has_ck = has_cookies($plat);
  my $tail;
  if ($used_cookies) {
    $tail = "所有办法（包括你上传的 cookies）都试过了。cookies 可能过期了，请重新导出一份上传；也可能这台 VPS 的 IP 被 $src 拉黑得比较严重，过几个小时再试。";
  } elsif (!$has_ck && $last_hint eq 'cookies') {
    $tail = $plat eq 'youtube'
      ? '不用账号的办法都试过了。最后一招：上传一个 YouTube 小号的 cookies（步骤见网页下面的「被拦住了？上传 cookies」）。'
      : '不用账号的办法都试过了' . (@tried ? '（' . join('、', @tried) . '）' : '') . "。$pname 对海外服务器限制很严，"
        . "请上传 $pname 的 cookies 再试（步骤见网页下面的「被拦住了？上传 cookies」，建议用小号）。";
  } else {
    $tail = '能试的办法都试过了，过一会儿再试一次。';
  }
  fail_job($id, "$last_msg $tail", $has_ck && !$used_cookies ? '' : $last_hint);
}

# 运行记录超过 2MB 时，只留最后 200KB，免得把硬盘慢慢写满。
sub trim_log {
  my $f = $C{log};
  return unless $f && -f $f && -s $f > 2 * 1024 * 1024;
  open(my $in, "<", $f) or return;
  seek($in, -200 * 1024, 2);
  local $/;
  my $tail = <$in>;
  close $in;
  $tail =~ s/\A[^\n]*\n//;
  open(my $out, ">", $f) or return;
  print $out "[日志太长，前面的已删掉]\n", $tail;
  close $out;
}

#----------------------------------------------------------------------
# 定时清理：传完的文件过一会儿删，放太久没人拿的也删，旧任务记录也删。
#----------------------------------------------------------------------
sub sweep {
  my $now = time;
  trim_log();
  for my $id (list_jobs()) {
    my $dir = job_dir($id);
    my $st = job_stat($id);
    my $meta = job_meta($id);
    my $state = $st->{state} || 'queued';
    my $created = $meta->{created} || (stat($dir))[9] || $now;
    if ($state eq 'done') {
      my $path = media_path($id);
      if ($path) {
        my $size = $st->{size} || -s $path || 0;
        my $busy = active_transfers($id);
        if (!$busy && $size && delivered_bytes($id, $size) >= $size) {
          my $sent_at = (stat("$dir/sent"))[9] || $now;
          if ($now - $sent_at >= $C{grace}) {
            # 送达了：文件和这条任务记录一起删掉，网页上也不会再出现。
            remove_tree($dir);
            logline("已送达，删除服务器文件和任务记录 $id");
            next;
          }
        } elsif (!$busy && $now - ($st->{done_at} || $created) > $C{keep_hours} * 3600) {
          unlink $path;
          set_stat($id, gone => "放了 $C{keep_hours} 小时没人来拿，服务器上的文件已自动删除。要的话重新贴一次链接。");
          logline("放太久，删除服务器文件 $id");
        }
      }
    }
    if ($state ne 'running' && $now - $created > 86400) {
      remove_tree($dir);
    } elsif ($state eq 'error' && $now - $created > 6 * 3600) {
      remove_tree($dir);
    }
  }
  # 下载程序临时解压的东西，万一被强制停止会留下。超过 6 小时的删掉。
  if (opendir(my $dh, "$DATA/tmp")) {
    for my $f (readdir $dh) {
      next if $f eq '.' || $f eq '..';
      my $p = "$DATA/tmp/$f";
      my $age = $now - ((lstat($p))[9] || $now);
      next if $age < 6 * 3600;
      if (-d $p) { remove_tree($p); } else { unlink $p; }
    }
    closedir $dh;
  }
}

#----------------------------------------------------------------------
# 网页（登录页和主页面）。不用外网的任何东西，打开就能用。
#----------------------------------------------------------------------
my $CSS = <<'CSS';
*{box-sizing:border-box}body{margin:0;font:16px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif;background:#f4f5f7;color:#1d1d1f}
main{max-width:760px;margin:0 auto;padding:24px 16px 60px}h1{font-size:26px;margin:8px 0 4px}.sub{color:#555;margin:0 0 18px}
.card{background:#fff;border-radius:14px;padding:18px;margin:14px 0;box-shadow:0 1px 3px rgba(0,0,0,.08)}
input[type=text],input[type=password],textarea{width:100%;font-size:17px;padding:12px;border:1px solid #c7c7cc;border-radius:10px;background:#fff}
textarea{font:13px/1.4 ui-monospace,Menlo,monospace;height:120px}
button,.btn{font-size:17px;padding:11px 20px;border:0;border-radius:10px;background:#0a7cff;color:#fff;cursor:pointer;text-decoration:none;display:inline-block}
button.gray,.btn.gray{background:#e5e5ea;color:#1d1d1f}button.red{background:#ff3b30}button:disabled{opacity:.5}
.qs label{display:block;padding:6px 2px;cursor:pointer}.row{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-top:12px}
.msg{padding:10px 14px;border-radius:10px;margin:10px 0;display:none}.msg.ok{display:block;background:#e8f5e9}.msg.bad{display:block;background:#ffebee;color:#b00020}
.job .t{font-weight:600;word-break:break-all}.job .l{color:#333;margin:6px 0}.bar{height:8px;background:#e5e5ea;border-radius:4px;overflow:hidden}
.bar i{display:block;height:100%;background:#34c759;width:0}.err{background:#fff4f4;border-left:4px solid #ff3b30;padding:10px;border-radius:6px;margin:8px 0;white-space:pre-wrap}
.small{font-size:13px;color:#666}details{margin:14px 0}summary{cursor:pointer;font-weight:600;padding:6px 0}ol{padding-left:22px}code{background:#eee;padding:1px 5px;border-radius:4px}
.top{display:flex;justify-content:space-between;align-items:center}.top a{color:#666;font-size:14px}
textarea.big{font:17px/1.5 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;height:auto;min-height:56px;resize:vertical}
.okline{color:#1b7f3b;font-weight:600}button.tiny{font-size:13px;padding:4px 10px;margin:2px 4px}
CSS

sub page_simple {
  my ($title, $text) = @_;
  return "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>"
    . html_esc($title) . "</title><style>$CSS</style></head><body><main><div class=\"card\"><h1>" . html_esc($title)
    . "</h1><p>" . html_esc($text) . "</p><p><a class=\"btn\" href=\"/\">回到首页</a></p></div></main></body></html>";
}

sub page_login {
  my ($msg) = @_;
  my $m = $msg ? '<div class="msg bad">' . html_esc($msg) . '</div>' : '';
  return <<"HTML";
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>登录 · 存视频到 Mac</title><style>$CSS</style></head><body><main>
<h1>存视频到 Mac</h1><p class="sub">先登录。名字和密码是安装时屏幕上显示的那一对。</p>
<form class="card" method="post" action="/login">$m
<p>登录名字<br><input type="text" name="user" value="admin" autocomplete="username" autocapitalize="off"></p>
<p>密码<br><input type="password" name="pass" autocomplete="current-password" autofocus></p>
<button type="submit">登录</button>
<p class="small">忘了密码：在 VPS 上输入 <code>ytdlp-web --status</code> 查看，或 <code>ytdlp-web --reset-password</code> 换一把。</p>
</form></main></body></html>
HTML
}

sub page_app {
  return <<"HTML" . <<'JS';
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>存视频到 Mac</title><style>$CSS</style></head><body><main>
<div class="top"><h1>存视频到 Mac</h1><a href="/logout">退出登录</a></div>
<p class="sub">贴链接 → 点「开始」→ 视频（或图片）自动存进 Mac 的「下载」文件夹，传完服务器上的文件自动删掉。<br>
支持 YouTube、抖音、小红书、B站、TikTok、推特/X、Instagram。App 里「分享 → 复制链接」得到的<b>整段文字</b>直接粘贴就行。</p>
<form class="card" id="f">
<textarea id="url" class="big" rows="2" placeholder="在这里粘贴视频链接，或整段分享文字（例如「6.99 复制打开抖音…… https://v.douyin.com/……」）" autocomplete="off" autofocus></textarea>
<div class="qs" style="margin-top:10px">
<label><input type="radio" name="q" value="mac" checked> Mac 能直接播放的最高画质（推荐。H.264 的 MP4；YouTube 一般 1080p。少数只有 VP9/AV1 的视频会自动转码，比较慢，网页会告诉你大概要等多久）</label>
<label><input type="radio" name="q" value="best"> 最高画质（4K/8K，原格式不转码，文件大。常是 VP9/AV1，Mac 自带播放器可能放不了，要装免费的 IINA 或 VLC）</label>
<label><input type="radio" name="q" value="p720"> 720p（文件小，下得快）</label>
<label><input type="radio" name="q" value="m4a"> 只要声音（m4a，Mac 的「音乐」能直接放）</label>
<label><input type="radio" name="q" value="mp3"> 只要声音（mp3）</label>
</div>
<div class="row"><button type="submit" id="go">开始</button><span class="small">第一次自动保存时，Safari 会问「是否允许下载」，请点「允许」。</span></div>
<div class="msg" id="msg"></div>
</form>
<div class="msg" id="upg"></div>
<div id="jobs"></div>
<details class="card" id="ck"><summary>被拦住了？上传 cookies（最后一招）</summary>
<div id="ckstate" class="small"></div>
<p>VPS 是海外机房的 IP，各平台都会提防。网页会先自动换几种<b>不用账号</b>的办法（换 IPv6/IPv4、换线路……）；都不行时，才需要你上传那个平台的 cookies（浏览器里的登录记录）。</p>
<p><b>请用小号，不要用主号</b>：平台发现账号被程序用，可能会限制甚至封号。cookies 过几周到几个月会失效，失效时网页会提醒你重新上传。
可以分几次上传不同平台的，互不覆盖。</p>
<p><b>大概什么时候要 cookies：</b>TikTok、推特、Instagram 的公开内容一般不用；YouTube 偶尔要；<b>抖音、小红书、B站</b>对海外服务器管得严，网页办法拿不到时就要。
YouTube 年龄限制、会员视频，推特敏感内容，B站大会员视频，一定要登录过的 cookies。</p>
<p><b>YouTube</b>（步骤特别一点，这样 cookies 不容易失效）：</p>
<ol>
<li>Mac 上用 <b>Chrome</b>（或 Firefox）。Safari 没有好用的导出工具。</li>
<li>Chrome 网上应用店搜索并安装扩展 <b>Get cookies.txt LOCALLY</b>（Firefox 装 <b>cookies.txt</b>）。在扩展的「详情」里打开「在无痕模式下启用」。</li>
<li>打开一个<b>无痕窗口</b>（Chrome 菜单「文件 → 打开新的无痕窗口」），在里面登录你的 YouTube 小号。</li>
<li>在同一个标签页的地址栏打开 <code>https://www.youtube.com/robots.txt</code></li>
<li>点浏览器右上角的扩展图标，选 <b>Export</b>（格式选 Netscape），会下载一个 <code>www.youtube.com_cookies.txt</code>。</li>
<li>直接关掉这个无痕窗口，以后别再打开它（这样 cookies 不会被 YouTube 换掉）。</li>
<li>回到这里，点下面「选择文件」选刚才那个 txt（或者把文件内容粘贴进框里），再点「保存 cookies」。</li>
</ol>
<p><b>抖音 / 小红书 / B站 / TikTok / 推特 / Instagram</b>：</p>
<ol>
<li>同样在 Chrome 装好 <b>Get cookies.txt LOCALLY</b>。</li>
<li>普通窗口打开对应网站：抖音 <code>https://www.douyin.com/</code>、小红书 <code>https://www.xiaohongshu.com/explore</code>、B站 <code>https://www.bilibili.com/</code>、TikTok <code>https://www.tiktok.com/</code>、推特 <code>https://x.com/</code>、Instagram <code>https://www.instagram.com/</code>。</li>
<li>登录你的<b>小号</b>（抖音可以先不登录：打开首页随便刷几个视频再导出，不行再登录）。</li>
<li>就在这个网站的页面上点扩展图标 → <b>Export</b>（Netscape 格式），得到一个 <code>xxx_cookies.txt</code>。</li>
<li>回到这里选文件 → 「保存 cookies」。以后这个平台被拦时，点任务上的「再试一次」就会用上。</li>
</ol>
<input type="file" id="ckfile" accept=".txt,text/plain">
<textarea id="cktext" placeholder="也可以把 cookies.txt 的内容整个粘贴到这里"></textarea>
<div class="row"><button type="button" id="cksave">保存 cookies</button><button type="button" class="gray" id="ckdel">删除全部 cookies</button></div>
<div class="msg" id="ckmsg"></div>
</details>
<details class="card"><summary>常见问题</summary>
<p><b>视频存在哪？</b> Mac 的「下载」文件夹（访达左边的「下载」）。Safari、Chrome 默认都存到这里。存好以后，网页上的那一条会显示 ✅ 然后自己消失。</p>
<p><b>图片帖（小红书图文、推特图片）？</b> 一张图直接存成图片；好几张会打成一个 zip，在 Mac 上双击就解开。纯文字的帖子没有东西可下，网页会告诉你。</p>
<p><b>点了开始，下好了却没有保存？</b> Safari 第一次会问「是否允许在此网站上下载」，点「允许」。Chrome 如果问「此网站想下载多个文件」，点「允许」。也可以点任务里的「保存到 Mac」按钮。</p>
<p><b>下载到一半网断了？</b> 在浏览器的下载列表里点「继续/恢复」，会接着下，不用从头来。服务器上的文件会等你拿完再删（最多留几个小时）。</p>
<p><b>为什么有的要「转码」，等很久？</b> Mac 自带播放器只认 H.264。网页总是先找现成的 H.264；只有原视频只有 VP9/AV1 时才转码。这台 VPS 只有 1 核，转码大约和视频一样长甚至更久。不想等就选「最高画质」，用 IINA/VLC 播放。</p>
<p><b>4K 视频 QuickTime 打不开？</b> 4K 一般是 VP9/AV1 格式，装一个免费的 IINA 或 VLC 就能放。想直接用 QuickTime，就选第一项。</p>
<p><b>可以关掉网页吗？</b> 服务器下载时可以关，下好后重新打开网页，在任务里点「保存到 Mac」。</p>
</details>
<p class="small" id="foot"></p>
</main>
HTML
<script>
const $=s=>document.querySelector(s);
const load=k=>{try{return new Set(JSON.parse(localStorage.getItem(k)||'[]'))}catch(e){return new Set()}};
const mine=load('ytw_mine'),got=load('ytw_got'),closing=new Set();
function keep(){localStorage.setItem('ytw_mine',JSON.stringify([...mine].slice(-60)));localStorage.setItem('ytw_got',JSON.stringify([...got].slice(-60)));}
async function api(p,data){const o={headers:{'X-YTW':'1'},cache:'no-store'};if(data){o.method='POST';o.body=new URLSearchParams(data);}
 const r=await fetch(p,o);if(r.status===401){location.href='/';throw new Error('login');}return r.json();}
function say(el,t,bad){el.textContent=t;el.className='msg '+(bad?'bad':'ok');}
const lastQ=localStorage.getItem('ytw_q');if(lastQ){const x=document.querySelector('input[name=q][value="'+lastQ+'"]');if(x)x.checked=true;}
$('#url').addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();$('#f').requestSubmit();}});
$('#f').onsubmit=async e=>{e.preventDefault();const url=$('#url').value.trim();
 if(!url){say($('#msg'),'先把视频链接（或整段分享文字）粘贴到上面的框里。',1);return;}
 const q=document.querySelector('input[name=q]:checked').value;localStorage.setItem('ytw_q',q);$('#go').disabled=true;
 try{const r=await api('/api/add',{url,q});if(r.error){say($('#msg'),r.error,1);}else{mine.add(r.id);keep();$('#url').value='';
  say($('#msg'),r.note||'收到了！下面能看到进度。下好以后会自动存到 Mac，不用一直盯着。');tick();}}
 catch(err){say($('#msg'),'暂时连不上服务器。可能正在升级重启，等半分钟再点一次「开始」；一直不行再检查网络。',1);}finally{$('#go').disabled=false;}};
function saveFile(id){const a=document.createElement('a');a.href='/dl/'+id;a.download='';document.body.appendChild(a);a.click();a.remove();}
function el(tag,cls,text){const e=document.createElement(tag);if(cls)e.className=cls;if(text!=null)e.textContent=text;return e;}
// 已经存到 Mac 的：亮 1.5 秒 ✅，然后告诉服务器收起来，卡片消失。
function dismiss(id){if(closing.has(id))return;closing.add(id);setTimeout(async()=>{try{await api('/api/dismiss',{id});}catch(e){}tick();},1500);}
// 服务器升级时显示一句安心的话；连不上（正在重启那几秒）时不报错，过一会儿自动接着刷新。
function render(d){const box=$('#jobs');box.textContent='';
 const u=$('#upg');if(d.info&&d.info.upgrading)say(u,'服务器正在升级：正在下载的会先下完，然后自动重启，排队的重启后自动接着下。不用管，也不用刷新网页。');else{u.className='msg';u.textContent='';}
 for(const j of d.jobs){const c=el('div','card job');c.appendChild(el('div','t',j.title||j.url));
  c.appendChild(el('div','small',(j.plat?j.plat+' · ':'')+j.quality+(j.size?' · '+j.size:'')));
  if(j.state==='error'){c.appendChild(el('div','err',j.error));}
  else{c.appendChild(el('div','l'+(j.delivered?' okline':''),j.line));if(j.note)c.appendChild(el('div','small',j.note));
   if(j.state==='running'||j.state==='queued'){const b=el('div','bar');const i=el('i');i.style.width=(j.pct||0)+'%';b.appendChild(i);c.appendChild(b);}}
  if(j.delivered){box.appendChild(c);dismiss(j.id);continue;}
  const row=el('div','row');
  if(j.has_file){const b=el('button',null,'保存到 Mac');b.onclick=()=>{got.add(j.id);keep();saveFile(j.id);};row.appendChild(b);}
  if(j.hint==='cookies'){const b=el('button','gray','去上传 cookies');b.onclick=()=>{$('#ck').open=true;$('#ck').scrollIntoView({behavior:'smooth'});};row.appendChild(b);}
  if(j.state==='error'){const b=el('button','gray','再试一次');b.onclick=async()=>{const r=await api('/api/add',{url:j.url,q:j.q});if(r.id){mine.add(r.id);keep();await api('/api/delete',{id:j.id});tick();}};row.appendChild(b);}
  const del=el('button','gray',j.state==='running'?'取消':'删除');del.onclick=async()=>{await api('/api/delete',{id:j.id});tick();};row.appendChild(del);
  c.appendChild(row);box.appendChild(c);
  if(j.state==='done'&&j.has_file&&mine.has(j.id)&&!got.has(j.id)){got.add(j.id);keep();saveFile(j.id);}}
 const i=d.info;let f='yt-dlp '+(i.ytdlp||'?')+(i.updated?'（'+i.updated+' 检查过更新，每天自动更新）':'（每天自动更新）');
 if(i.method)f+=' · YouTube 上次成功的办法：'+i.method;f+=' · YouTube 被拦时会依次试：'+i.methods.join(' → ');
 f+=' · 传到 Mac 后约 '+i.grace_min+' 分钟删除服务器文件，没人拿的 '+i.keep_hours+' 小时后删除';if(i.free)f+=' · 服务器硬盘剩 '+i.free;
 $('#foot').textContent=f;
 const st=$('#ckstate');st.textContent='';
 if(!i.cookie_sites.length){st.textContent='还没有上传任何 cookies。大多数时候不需要。';}
 else{st.appendChild(el('span',null,'已上传（'+i.cookies_at+' 更新）：'));
  for(const s of i.cookie_sites){const b=el('button','gray tiny',s.name+(s.bad?'（已失效，请重新上传）':'')+' ✕');b.title='删除 '+s.name+' 的 cookies';
   b.onclick=async()=>{await api('/api/cookies/delete',{plat:s.key});say($('#ckmsg'),'已删除 '+s.name+' 的 cookies。');tick();};st.appendChild(b);}
  st.appendChild(el('span',null,' 只有前面的办法都不行时才会用。'));}
 if(i.cookies_bad)$('#ck').open=true;
 return d.jobs.some(j=>j.state==='queued'||j.state==='running'||(j.state==='done'&&(j.has_file||j.delivered)));}
let timer=null;
async function tick(){clearTimeout(timer);let busy=false;try{busy=render(await api('/api/jobs'));}catch(e){}timer=setTimeout(tick,busy?1500:8000);}
$('#ckfile').onchange=e=>{const f=e.target.files[0];if(!f)return;const r=new FileReader();r.onload=()=>{$('#cktext').value=r.result;};r.readAsText(f);};
$('#cksave').onclick=async()=>{const r=await api('/api/cookies',{text:$('#cktext').value});if(r.error)say($('#ckmsg'),r.error,1);else{say($('#ckmsg'),'保存好了（'+(r.sites||[]).join('、')+'）。被拦的任务点「再试一次」就会用上。');$('#cktext').value='';$('#ckfile').value='';tick();}};
$('#ckdel').onclick=async()=>{await api('/api/cookies/delete',{});say($('#ckmsg'),'已删除服务器上的全部 cookies。');tick();};
tick();
</script></body></html>
JS
}

#----------------------------------------------------------------------
# 主循环：开端口、接浏览器、排队下载、定时清理。
#----------------------------------------------------------------------
sub open_listeners {
  my @socks;
  my $host = $C{listen};
  if ($host eq '0.0.0.0' && eval { require IO::Socket::IP; 1 }) {
    my $s = IO::Socket::IP->new(LocalHost => '::', LocalPort => $C{port}, Listen => 64, ReuseAddr => 1, V6Only => 0, Proto => 'tcp');
    push @socks, $s if $s;
  }
  unless (@socks) {
    my $s = IO::Socket::INET->new(LocalAddr => $host, LocalPort => $C{port}, Listen => 64, ReuseAddr => 1, Proto => 'tcp');
    die "端口 $C{port} 打不开：$!\n" unless $s;
    push @socks, $s;
  }
  return @socks;
}

sub main {
  my @ls = open_listeners();
  $0 = 'ytdlp-web';
  spit("$STATE/server.pid", "$$\n");
  logline("网页已启动，端口 $C{port}，版本 $VERSION");
  # 上次没下完就被重启的任务，标成失败，免得一直卡在“下载中”。
  for my $id (list_jobs()) {
    my $s = job_stat($id)->{state} || '';
    fail_job($id, '服务器重启了，这个下载被打断。点「再试一次」就行。', '') if $s eq 'running';
  }
  my $sel = IO::Select->new(@ls);
  my %handlers;
  my ($runner, $runner_job) = (0, '');
  my $last_sweep = 0;
  my $stop = 0;
  $SIG{TERM} = $SIG{INT} = sub { $stop = 1; };
  $SIG{HUP} = 'IGNORE';
  while (!$stop) {
    for my $l ($sel->can_read(1)) {
      my $c = $l->accept or next;
      if (keys(%handlers) >= 40) {
        respond($c, undef, 503, 'text/plain; charset=utf-8', "busy\n");
        close $c;
        next;
      }
      my $pid = fork();
      if (!defined $pid) { close $c; next; }
      if ($pid == 0) {
        $SIG{TERM} = $SIG{INT} = 'DEFAULT';
        close $_ for @ls;
        eval { handle($c); };
        logline("请求出错：$@") if $@;
        close $c;
        POSIX::_exit(0);
      }
      $handlers{$pid} = 1;
      close $c;
    }
    while ((my $k = waitpid(-1, WNOHANG)) > 0) {
      delete $handlers{$k};
      if ($k == $runner) { $runner = 0; $runner_job = ''; }
    }
    # 每天的 yt-dlp 更新也在这里排队：和下载是同一个「跑腿」进程一件一件做，
    # 所以更新时一定没有视频在下，不会把 yt-dlp 换掉在正在下的任务脚下。
    # 安装脚本在升级（挂了牌子）时，什么新活都先不派。
    if (!$runner && !upgrading()) {
      my ($next) = grep { (job_stat($_)->{state} || 'queued') eq 'queued' } list_jobs();
      my $task = $next ? "job:$next" : (update_due($C{update_hours}) ? 'update' : '');
      if ($task) {
        my $pid = fork();
        if (defined $pid && $pid == 0) {
          $SIG{TERM} = $SIG{INT} = \&runner_stop;
          close $_ for @ls;
          if ($next) { eval { run_job($next) }; fail_job($next, "出错了：$@", '') if $@; }
          else { $0 = 'ytdlp-web-update'; update_ytdlp('每天一次'); }
          POSIX::_exit(0);
        }
        if (defined $pid) {
          # 先在父进程里标上“下载中”，免得下一圈又把它派出去一次。
          set_stat($next, state => 'running', line => '准备中…') if $next;
          ($runner, $runner_job) = ($pid, $next || 'update');
        }
      }
    }
    if (time - $last_sweep >= ($C{sweep_secs} || 30)) {
      $last_sweep = time;
      eval { sweep() };
      logline("清理出错：$@") if $@;
    }
  }
  logline('收到停止信号，正在退出');
  kill 'TERM', $runner if $runner;
  kill 'TERM', keys %handlers;
  exit 0;
}

main() unless $ENV{YTDLP_WEB_NO_MAIN};
1;
YTDLP_WEB_SERVER_EOF
  if ! perl -c "$LIB_DIR/server.pl.new" >/dev/null 2>&1; then
    why=$(perl -c "$LIB_DIR/server.pl.new" 2>&1 | head -n 3 | tr '\n' ' ')
    rm -f "$LIB_DIR/server.pl.new"
    die "网页程序在这台机器的 Perl 上跑不起来：$why"
  fi
  chmod 755 "$LIB_DIR/server.pl.new"
  mv "$LIB_DIR/server.pl.new" "$LIB_DIR/server.pl"
}

#----------------------------------------------------------------------
# 开机自动启动：先写一个小启动脚本，再按这台机器的启动方式登记。
#----------------------------------------------------------------------
write_runner() {
  mkdir -p /usr/local/sbin
  cat > "$RUNNER" <<EOF
#!/bin/sh
# ytdlp-web 网页服务的启动脚本。开机时由系统调用，记录写到 $LOG_FILE
mkdir -p "$DATA"
exec perl "$LIB_DIR/server.pl" "$CONF_FILE" >> "$LOG_FILE" 2>&1
EOF
  chmod 755 "$RUNNER"
}

write_service() {
  case "$INIT" in
    systemd)
      cat > /etc/systemd/system/ytdlp-web.service <<EOF
[Unit]
Description=ytdlp-web (save videos to Mac)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$RUNNER
WorkingDirectory=/
Restart=always
RestartSec=3
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
      systemctl enable ytdlp-web >/dev/null 2>&1 || true
      ;;
    openrc)
      cat > /etc/init.d/ytdlp-web <<EOF
#!/sbin/openrc-run
name="ytdlp-web"
description="ytdlp-web (save videos to Mac)"
command="$RUNNER"
command_background=true
pidfile="/run/ytdlp-web.pid"

depend() {
  need net
}
EOF
      chmod 755 /etc/init.d/ytdlp-web
      rc-update add ytdlp-web default >/dev/null 2>&1 || true
      ;;
    procd)
      cat > /etc/init.d/ytdlp-web <<EOF
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
start_service() {
  procd_open_instance
  procd_set_param command $RUNNER
  procd_set_param respawn 3600 5 0
  procd_close_instance
}
EOF
      chmod 755 /etc/init.d/ytdlp-web
      /etc/init.d/ytdlp-web enable >/dev/null 2>&1 || true
      ;;
    *)
      cat > /etc/init.d/ytdlp-web <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ytdlp-web
# Required-Start:    \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: ytdlp-web (save videos to Mac)
### END INIT INFO
PIDFILE=/run/ytdlp-web.pid
case "\$1" in
  start)
    mkdir -p /run
    if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null; then
      exit 0
    fi
    if command -v setsid >/dev/null 2>&1; then
      setsid $RUNNER </dev/null >/dev/null 2>&1 &
    else
      $RUNNER </dev/null >/dev/null 2>&1 &
    fi
    echo \$! > "\$PIDFILE"
    ;;
  stop)
    if [ -f "\$PIDFILE" ]; then
      kill "\$(cat "\$PIDFILE")" 2>/dev/null || true
      rm -f "\$PIDFILE"
    fi
    ;;
  restart)
    "\$0" stop
    sleep 1
    "\$0" start
    ;;
  *)
    echo "usage: \$0 {start|stop|restart}" >&2
    exit 1
    ;;
esac
EOF
      chmod 755 /etc/init.d/ytdlp-web
      if [ -f /etc/rc.local ]; then
        if ! grep -q '/etc/init.d/ytdlp-web start' /etc/rc.local 2>/dev/null; then
          if [ -s /etc/rc.local ] && [ -n "$(tail -c 1 /etc/rc.local 2>/dev/null)" ]; then
            printf '\n' >> /etc/rc.local
          fi
          if grep -q '^exit 0' /etc/rc.local 2>/dev/null; then
            sed -i 's#^exit 0#/etc/init.d/ytdlp-web start\nexit 0#' /etc/rc.local 2>/dev/null || true
          else
            printf '%s\n' '/etc/init.d/ytdlp-web start' >> /etc/rc.local
          fi
        fi
        chmod +x /etc/rc.local 2>/dev/null || true
      fi
      if have update-rc.d; then
        update-rc.d ytdlp-web defaults >/dev/null 2>&1 || true
      elif have chkconfig; then
        chkconfig --add ytdlp-web >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

stop_service() {
  case "$INIT" in
    systemd) systemctl stop ytdlp-web >/dev/null 2>&1 || true ;;
    openrc) rc-service ytdlp-web stop >/dev/null 2>&1 || true ;;
    *) [ -x /etc/init.d/ytdlp-web ] && /etc/init.d/ytdlp-web stop >/dev/null 2>&1 || true ;;
  esac
  # 启动方式认错、或者旧记录残留时，按网页自己记下的进程号再停一次。
  for pf in /run/ytdlp-web.pid "$DATA/state/server.pid"; do
    if [ -f "$pf" ]; then
      kill "$(cat "$pf")" >/dev/null 2>&1 || true
      rm -f "$pf"
    fi
  done
  sleep 1
}

start_service() {
  case "$INIT" in
    systemd) systemctl restart ytdlp-web ;;
    openrc) rc-service ytdlp-web restart ;;
    *) /etc/init.d/ytdlp-web restart || /etc/init.d/ytdlp-web start ;;
  esac
}

# 旧版（1.x）用的服务。升级和卸载时要先停掉，端口才空得出来。
stop_old_service() {
  if have systemctl && [ -f /etc/systemd/system/yt-dlp-webui.service ]; then
    systemctl stop yt-dlp-webui >/dev/null 2>&1 || true
    systemctl disable yt-dlp-webui >/dev/null 2>&1 || true
  fi
  if [ -x /etc/init.d/yt-dlp-webui ]; then
    if [ "$INIT" = openrc ]; then
      rc-service yt-dlp-webui stop >/dev/null 2>&1 || true
      rc-update del yt-dlp-webui default >/dev/null 2>&1 || true
    else
      /etc/init.d/yt-dlp-webui stop >/dev/null 2>&1 || true
    fi
  fi
  if [ -f /run/yt-dlp-webui.pid ]; then
    kill "$(cat /run/yt-dlp-webui.pid)" >/dev/null 2>&1 || true
    rm -f /run/yt-dlp-webui.pid
  fi
}

# 新版装好、跑起来以后，把旧版的程序和服务清掉。旧版下好的视频不删，告诉你在哪。
remove_old_install() {
  stop_old_service
  rm -f /etc/systemd/system/yt-dlp-webui.service
  have systemctl && systemctl daemon-reload >/dev/null 2>&1 || true
  rm -f /etc/init.d/yt-dlp-webui
  if [ -f /etc/rc.local ]; then
    fstab_remove_line /etc/rc.local '/etc/init.d/yt-dlp-webui start'
  fi
  if have update-rc.d; then
    update-rc.d -f yt-dlp-webui remove >/dev/null 2>&1 || true
  fi
  # 旧版做的虚拟内存还在用，就交给新版管，卸载时一起删。
  if [ -f /etc/yt-dlp-webui/swap.size ] && [ -f /yt-dlp-webui.swap ]; then
    mkdir -p "$CONF_DIR"
    printf '%s\n' /yt-dlp-webui.swap > "$CONF_DIR/swap.old"
  fi
  if [ -f /etc/yt-dlp-webui/ffmpeg-static ]; then
    mkdir -p "$CONF_DIR"
    printf '%s\n' static > "$CONF_DIR/ffmpeg-static"
  fi
  if [ -f /etc/sysctl.d/99-yt-dlp-webui-overcommit.conf ]; then
    mv /etc/sysctl.d/99-yt-dlp-webui-overcommit.conf /etc/sysctl.d/99-ytdlp-web-overcommit.conf 2>/dev/null || true
  fi
  rm -f /usr/local/bin/yt-dlp-webui /usr/local/bin/yt-dlp-one /usr/local/sbin/yt-dlp-webui-run
  rm -rf /etc/yt-dlp-webui /usr/local/share/yt-dlp-webui
  rm -f /var/log/yt-dlp-webui.log /var/log/yt-dlp-webui.service.log
  for d in /var/lib/yt-dlp-webui /yt-dlp-webui-data; do
    [ -d "$d" ] || continue
    rm -f "$d"/*.db "$d"/*.db-* "$d/download.lock" 2>/dev/null || true
    rm -rf "${d:?}/tmp" "${d:?}/cache" "${d:?}/home" 2>/dev/null || true
    if [ -d "$d/downloads" ] && [ -n "$(ls -A "$d/downloads" 2>/dev/null)" ]; then
      say_warn "旧版下在 VPS 上的视频还在 $d/downloads 。不要的话可以输入：rm -rf $d"
    else
      rm -rf "$d"
    fi
  done
  say_ok "旧版网页（yt-dlp-web-ui）已经清掉"
}

#----------------------------------------------------------------------
# 端口：有没有被占用、是不是我们自己的网页、网页有没有起来。
#----------------------------------------------------------------------
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

health_once() {
  port=$1
  out=
  if have curl; then
    out=$(curl -s --noproxy '*' --max-time 3 "http://127.0.0.1:${port}/health" 2>/dev/null || true)
  elif have wget; then
    out=$(no_proxy=127.0.0.1 NO_PROXY=127.0.0.1 wget -q -T 3 -O - "http://127.0.0.1:${port}/health" 2>/dev/null || true)
  fi
  case "$out" in
    'ytdlp-web ok'*) return 0 ;;
  esac
  return 1
}

# 我们自己的网页（或者马上要被换掉的旧版）占着这个端口没关系，别的程序占着就不行。
port_taken_by_other() {
  port=$1
  port_busy "$port" || return 1
  health_once "$port" && return 1
  old=$(old_config_get port 2>/dev/null || true)
  [ -n "$old" ] && [ "$port" = "$(normalize_port "$old" 2>/dev/null)" ] && return 1
  return 0
}

health_ok() {
  port=$1
  i=0
  while [ "$i" -lt 25 ]; do
    health_once "$port" && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

show_fail_log() {
  say_err "网页没有起来。最近的记录："
  if [ "$INIT" = systemd ] && have journalctl; then
    journalctl -u ytdlp-web -n 20 --no-pager 2>/dev/null || true
  fi
  if [ -f "$LOG_FILE" ]; then
    tail -n 30 "$LOG_FILE" 2>/dev/null || true
  fi
}

# 你选了“浏览器直接打开”，并且本机防火墙开着时，放开这个 TCP 端口。
open_firewall() {
  port=$1
  if have ufw && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    if ufw allow "${port}/tcp" >/dev/null 2>&1; then
      say_ok "ufw 已放开 ${port}/tcp"
    else
      say_warn "ufw 没能放开 ${port}"
    fi
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

#----------------------------------------------------------------------
# 这台机器的地址。只有内网地址时，再问一下外面看到的公网 IP，好告诉你打开哪个网址。
#----------------------------------------------------------------------
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
    case "$ip" in 127.*|::1) continue ;; esac
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
  ADDR_PUBLIC=$ADDR_V4
  if [ -z "$ADDR_PUBLIC" ] && [ "${YTD_TEST:-}" != 1 ]; then
    for u in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
      got=
      if have curl; then
        got=$(curl -4 -s --max-time 6 "$u" 2>/dev/null | tr -d ' \r\n' || true)
      elif have wget; then
        got=$(wget -q -T 6 -O - "$u" 2>/dev/null | tr -d ' \r\n' || true)
      fi
      if is_ipv4 "$got" && ! is_private_ipv4 "$got"; then
        ADDR_PUBLIC=$got
        break
      fi
    done
  fi
}

#----------------------------------------------------------------------
# 登录密码：存的是加密后的样子（SHA-512），网页服务拿它来核对。原文另外记一份给你看。
#----------------------------------------------------------------------
hash_password() {
  pass=$1
  salt=$(rand_hex 8) || return 1
  for pre in '$6$' '$5$' '$1$'; do
    h=$(YTD_P="$pass" YTD_S="${pre}${salt}\$" perl -e 'print crypt($ENV{YTD_P}, $ENV{YTD_S})' 2>/dev/null || true)
    case "$h" in
      "$pre"*) printf '%s\n' "$h"; return 0 ;;
    esac
  done
  return 1
}

write_install_note() {
  user=$1
  pass=$2
  port=$3
  mkdir -p "$CONF_DIR"
  umask 077
  {
    printf 'username=%s\n' "$user"
    printf 'password=%s\n' "$pass"
    printf 'port=%s\n' "$port"
  } > "$NOTE_FILE"
  chmod 600 "$NOTE_FILE"
  umask 022
}

#----------------------------------------------------------------------
# ytdlp-web 这个命令：其实就是这个脚本自己，拷一份放好。
#----------------------------------------------------------------------
install_cli() {
  mkdir -p /usr/local/sbin
  if [ -f "$0" ] && grep -q 'ytdlp-onekey-begin' "$0" 2>/dev/null; then
    if [ "$0" != "$CLI_FILE" ]; then
      cp "$0" "$CLI_FILE.new" && mv "$CLI_FILE.new" "$CLI_FILE"
    fi
    chmod 755 "$CLI_FILE"
  fi
  link=$(shortcut_link_dir "$PATH")
  if [ -n "$link" ]; then
    ln -sfn "$CLI_FILE" "$link/ytdlp-web"
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

# 运行前先看看 GitHub 上有没有更新的脚本，有就换新的接着跑。
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

#----------------------------------------------------------------------
# ytdlp-web --status：看看装得怎么样。
#----------------------------------------------------------------------
print_status() {
  detect_machine
  printf '%s\n' "系统：$OS_PRETTY"
  printf '%s\n' "包管理：$PM    架构：$ARCH    系统库：$LIBC    启动方式：$INIT"
  printf '%s\n' "内存：${MEM_MB:-未知}MB    虚拟内存：${SWAP_MB:-0}MB    磁盘剩余：${DISK_MB}MB"
  if [ -x /usr/local/bin/yt-dlp ]; then
    printf '%s\n' "yt-dlp：$(/usr/local/bin/yt-dlp --version 2>/dev/null | head -n 1)（网页服务每天自动更新）"
  else
    printf '%s\n' "yt-dlp：还没装"
  fi
  if qjs_eval_ok /usr/local/bin/qjs; then
    printf '%s\n' "QuickJS：能用"
  fi
  if need_tool ffmpeg; then
    printf '%s\n' "ffmpeg：能用"
  else
    printf '%s\n' "ffmpeg：没有（高画质合并会失败）"
  fi
  if [ -n "$(config_get pot 2>/dev/null || true)" ]; then
    printf '%s\n' "PO 令牌程序：已装（被拦时自动用）"
  else
    printf '%s\n' "PO 令牌程序：没装"
  fi
  if [ -n "$(config_get warp_conf 2>/dev/null || true)" ]; then
    printf '%s\n' "Cloudflare WARP：已准备好（被拦时自动用）"
  elif [ "$(config_get warp 2>/dev/null || true)" = 1 ]; then
    printf '%s\n' "Cloudflare WARP：你选了要，但还没准备好。运行 ytdlp-web 回车会重试"
  else
    printf '%s\n' "Cloudflare WARP：不用"
  fi
  if [ -s "$CONF_DIR/cookies.txt" ]; then
    printf '%s\n' "cookies：已上传（实在被拦时才用）"
  fi
  if ! install_ready; then
    if old_install_present; then
      printf '%s\n' "这里装的是旧版（下到 VPS 的那种）。运行 ytdlp-web 回车就升级成新版。"
    else
      printf '%s\n' "网页：还没装"
    fi
    return 0
  fi
  port=$(config_get port)
  user=$(config_get user)
  printf '%s\n' "端口：$port"
  printf '%s\n' "登录名字：$user"
  pass=$(read_saved_password 2>/dev/null || true)
  if [ -n "$pass" ]; then
    printf '%s\n' "密码：$pass"
  else
    printf '%s\n' "密码：记录丢了。运行 ytdlp-web --reset-password 可以换一把新的。"
  fi
  if health_once "$port"; then
    say_ok "网页正在运行"
  else
    say_warn "网页现在没有在运行。运行 ytdlp-web 回车可以重新装好并启动。"
  fi
  collect_addrs
  if [ "$(config_get open_mode 2>/dev/null || true)" = 2 ]; then
    printf '%s\n' "打开方式：SSH 转发。Mac 终端执行 ssh -L ${port}:127.0.0.1:${port} root@你的VPS ，再打开 http://127.0.0.1:${port}"
  elif [ -n "$ADDR_PUBLIC" ]; then
    printf '%s\n' "网址：http://${ADDR_PUBLIC}:${port}"
  fi
  printf '%s\n' "运行记录：$LOG_FILE （输入 ytdlp-web --log 查看最近的）"
}

print_log() {
  if [ -f "$LOG_FILE" ]; then
    tail -n "${1:-60}" "$LOG_FILE"
  else
    printf '%s\n' "还没有运行记录（$LOG_FILE）。"
  fi
}

#----------------------------------------------------------------------
# ytdlp-web --uninstall：先问一句再卸。直接回车不卸。
#----------------------------------------------------------------------
uninstall_all() {
  detect_machine
  printf '%s\n' "确定要卸掉吗？会删掉网页、yt-dlp、QuickJS、PO 令牌程序、WARP 和 VPS 上的临时视频。"
  printf '%s\n' "你 Mac 上已经保存的视频不受影响。"
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
      systemctl disable ytdlp-web >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/ytdlp-web.service
      systemctl daemon-reload >/dev/null 2>&1 || true
      ;;
    openrc)
      rc-update del ytdlp-web default >/dev/null 2>&1 || true
      ;;
    procd)
      [ -x /etc/init.d/ytdlp-web ] && /etc/init.d/ytdlp-web disable >/dev/null 2>&1 || true
      ;;
    *)
      if have update-rc.d; then
        update-rc.d -f ytdlp-web remove >/dev/null 2>&1 || true
      elif have chkconfig; then
        chkconfig --del ytdlp-web >/dev/null 2>&1 || true
      fi
      ;;
  esac
  rm -f /etc/init.d/ytdlp-web
  [ -f /etc/rc.local ] && fstab_remove_line /etc/rc.local '/etc/init.d/ytdlp-web start'
  if old_install_present; then
    remove_old_install
  fi
  for sf in "$SWAP_FILE" "$(cat "$CONF_DIR/swap.old" 2>/dev/null || true)"; do
    [ -n "$sf" ] && [ -f "$sf" ] || continue
    swapoff "$sf" >/dev/null 2>&1 || true
    rm -f "$sf"
    fstab_remove_line /etc/fstab "$sf none swap sw 0 0"
  done
  if [ -f "$CONF_DIR/ffmpeg-static" ]; then
    rm -f /usr/local/bin/ffmpeg /usr/local/bin/ffprobe
  fi
  rm -f /usr/local/bin/yt-dlp /usr/local/bin/qjs /usr/local/bin/bgutil-pot /usr/local/bin/wireproxy \
    "$RUNNER" /etc/sysctl.d/99-ytdlp-web-overcommit.conf "$LOG_FILE"
  rm -rf "$LIB_DIR" "$CONF_DIR" "$DATA"
  link=$(shortcut_link_dir "$PATH")
  [ -n "$link" ] && [ -L "$link/ytdlp-web" ] && rm -f "$link/ytdlp-web"
  rm -f "$CLI_FILE"
  say_ok "已经卸干净了。想再装，重新运行安装命令就行。"
}

#----------------------------------------------------------------------
# 问问题：一次一题，直接回车就是推荐的选项。
#----------------------------------------------------------------------
# 键盘不在脚本的输入上时（比如用 curl | sh 运行），改回真正的键盘。
# 不能写进 ask_line：测试用管道喂答案时，这里去读 /dev/tty 会卡住。
prepare_stdin() {
  [ "${YTD_TEST:-}" = 1 ] && return 0
  [ "$action" = install ] && auto_mode && return 0
  [ "${YTD_NO_TTY:-}" = 1 ] && return 0
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
    printf '直接按回车，会用：%s\n' "$_d"
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

ask_port() {
  saved_port=$(config_get port 2>/dev/null || old_config_get port 2>/dev/null || true)
  if ! port_prompt_default "$saved_port" >/dev/null 2>&1; then
    saved_port=
  else
    saved_port=$(port_prompt_default "$saved_port")
  fi
  printf '\n%s\n' "第 1 题：网页端口"
  printf '%s\n' "Mac 打开网页时，地址是 http://VPS的IP:端口 。端口就是冒号后面那个数字。"
  printf '%s\n' "请从 1 到 65535 里自己选一个，不要用 22。服务商给你开了哪个端口，就填哪个。"
  if [ -n "$saved_port" ]; then
    printf '%s\n' "这台 VPS 现在用的是 ${saved_port}。直接回车就继续用这个。"
  else
    printf '%s\n' "这一题要自己填，不能直接回车。例如 8080。"
  fi
  while true; do
    ask_line "想用哪个端口？" "$saved_port" PORT_CHOSEN
    PORT_CHOSEN=$(normalize_port "$PORT_CHOSEN" 2>/dev/null || printf '%s' "$PORT_CHOSEN")
    why=$(port_text_problem "$PORT_CHOSEN")
    case "$why" in
      ok) ;;
      ssh)
        say_warn "22 是你登录这台 VPS 用的，不能给网页。请另选一个，例如 8080。"
        continue
        ;;
      *)
        if [ -n "$saved_port" ]; then
          say_warn "请输入 1 到 65535 的数字。直接回车就用 ${saved_port}。"
        else
          say_warn "请输入 1 到 65535 的数字。这一题要自己填，例如 8080。"
        fi
        continue
        ;;
    esac
    if port_taken_by_other "$PORT_CHOSEN"; then
      say_warn "端口 ${PORT_CHOSEN} 已经有别的程序在用。请输入另一个数字，比如 8080。"
      saved_port=
      continue
    fi
    break
  done
}

ask_password() {
  reset_pass=$1
  PASS_MODE=new
  printf '\n%s\n' "第 3 题：登录密码"
  printf '%s\n' "打开网页要先登录，这样别人不能拿你的 VPS 去下载。"
  saved_pass=$(read_saved_password 2>/dev/null || true)
  saved_hash=$(config_get pass_hash 2>/dev/null || true)
  if [ "$reset_pass" != 1 ] && [ -n "$saved_pass" ] && [ -n "$saved_hash" ]; then
    printf '%s\n' "这台 VPS 已经有密码了。"
    printf '%s\n' "  1) 继续用现在的密码（推荐）"
    printf '%s\n' "  2) 换一把新密码"
    ask_menu PASS_KEEP 1 2
    if [ "$PASS_KEEP" = 1 ]; then
      PASS_MODE=keep
      PASS_CHOSEN=$saved_pass
      return 0
    fi
  fi
  printf '%s\n' "  1) 帮我随机生成一把（推荐，不容易被别人猜到）"
  printf '%s\n' "  2) 我自己设一个"
  ask_menu PASS_HOW 1 2
  if [ "$PASS_HOW" = 1 ]; then
    PASS_MODE=random
    PASS_CHOSEN=
    return 0
  fi
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
}

ask_settings() {
  reset_pass=$1
  say_step "先回答 5 个问题"
  printf '%s\n' "除了第 1 题的端口，其他题直接按回车就是推荐的选项。"
  ask_port

  saved_user=$(config_get user 2>/dev/null || true)
  [ -n "$saved_user" ] || saved_user="admin"
  printf '\n%s\n' "第 2 题：登录名字"
  printf '%s\n' "名字只用英文字母和数字。"
  while true; do
    ask_line "登录名字用什么？" "$saved_user" USER_CHOSEN
    case "$(user_text_problem "$USER_CHOSEN")" in
      ok) break ;;
      len) say_warn "名字太长了，请控制在 32 位以内。" ;;
      *) say_warn "名字里只能有英文字母和数字，例如 admin 或 xiaoming。" ;;
    esac
  done

  ask_password "$reset_pass"

  printf '\n%s\n' "第 4 题：Mac 怎么打开这个网页"
  collect_addrs
  if [ -n "$ADDR_V4" ]; then
    printf '%s\n' "这台 VPS 有公网地址 ${ADDR_V4}。"
  elif [ -n "$ADDR_PUBLIC" ]; then
    printf '%s\n' "这台 VPS 本机只有内网地址 ${ADDR_V4_PRIVATE:-?}，外面看到的地址是 ${ADDR_PUBLIC}。"
    printf '%s\n' "服务商给了端口映射（外网端口和你填的一样）时选 1。不确定也先选 1，打不开再重新运行选 2。"
  fi
  printf '%s\n' "  1) 浏览器直接打开 http://地址:端口（推荐）"
  printf '%s\n' "  2) 只用 SSH 转发（更安全，但每次都要先在 Mac 终端敲一行命令）"
  ask_menu OPEN_CHOSEN 1 2

  printf '\n%s\n' "第 5 题：被网站拦住时，要不要自动换 Cloudflare WARP 线路？"
  printf '%s\n' "VPS 是机房 IP，YouTube 等网站有时会说「请登录，确认你不是机器人」。"
  printf '%s\n' "网页会自动试好几种不用账号的办法，WARP 是其中一招：换成 Cloudflare 的出口 IP。"
  printf '%s\n' "选「要」会在 Cloudflare 免费匿名注册一个 WARP（不用邮箱、不花钱）。平时不开，被拦时才临时打开。"
  saved_warp=$(config_get warp 2>/dev/null || true)
  d=1
  [ "$saved_warp" = 0 ] && d=2
  printf '%s\n' "  1) 要（推荐）"
  printf '%s\n' "  2) 不要"
  ask_menu WARP_ANS "$d" 2
  if [ "$WARP_ANS" = 1 ]; then WARP_CHOSEN=1; else WARP_CHOSEN=0; fi
}

show_plan() {
  printf '\n%s\n' "请核对，接下来会按这个装："
  printf '%s\n' "  端口：${PORT_CHOSEN}"
  printf '%s\n' "  登录名字：${USER_CHOSEN}"
  case "$PASS_MODE" in
    keep) printf '%s\n' "  密码：继续用现在的" ;;
    custom) printf '%s\n' "  密码：用你设的那把" ;;
    *) printf '%s\n' "  密码：随机生成，装完会显示出来" ;;
  esac
  if [ "$OPEN_CHOSEN" = 2 ]; then
    printf '%s\n' "  Mac 打开方式：SSH 转发（网页只在 VPS 本机能打开）"
  else
    printf '%s\n' "  Mac 打开方式：浏览器直接打开"
  fi
  if [ "$WARP_CHOSEN" = 1 ]; then
    printf '%s\n' "  被拦时用 Cloudflare WARP：要"
  else
    printf '%s\n' "  被拦时用 Cloudflare WARP：不要"
  fi
  printf '\n%s\n' "  1) 开始安装（推荐）"
  printf '%s\n' "  2) 上面有选错的，重新答一遍"
}

#----------------------------------------------------------------------
# 全自动模式：一键命令前面加上 PORT=端口 ，就一个问题都不问。
#   PORT=15346          网页端口（第一次安装必须给）
#   WEB_USER=admin      登录名字（可不给，默认 admin）
#   WEB_PASS=...        登录密码（可不给，默认随机生成；已经装过就沿用原来的）
#   OPEN=1 或 2         1 浏览器直接打开（默认），2 只用 SSH 转发
#   WARP=1 或 0         被拦时要不要用 Cloudflare WARP（默认 1 要）
# 已经装过的机器，只写 YTD_AUTO=1 也行，就是按原来的设置自动更新。
#----------------------------------------------------------------------
auto_mode() {
  [ -n "${YTD_PORT:-}${PORT:-}" ] || [ "${YTD_AUTO:-}" = 1 ]
}

yes_value() {
  case "$1" in
    1|y|Y|yes|YES|on|true) printf '%s\n' 1 ;;
    0|n|N|no|NO|off|false) printf '%s\n' 0 ;;
    *) printf '%s\n' "$2" ;;
  esac
}

load_auto_choices() {
  want_port=${YTD_PORT:-${PORT:-}}
  saved_port=$(config_get port 2>/dev/null || old_config_get port 2>/dev/null || true)
  [ -n "$want_port" ] || want_port=$saved_port
  [ -n "$want_port" ] || die "全自动模式要告诉我端口。例如在安装命令前面加上 PORT=15346"
  PORT_CHOSEN=$(normalize_port "$want_port" 2>/dev/null) || die "端口 ${want_port} 不对，请用 1 到 65535 的数字。"
  case "$(port_text_problem "$PORT_CHOSEN")" in
    ok) ;;
    ssh) die "22 是登录 VPS 用的端口，不能给网页。请换一个，例如 PORT=8080" ;;
    *) die "端口 ${want_port} 不对，请用 1 到 65535 的数字。" ;;
  esac
  if [ "$MIGRATE" != 1 ] && [ "$PORT_CHOSEN" != "$saved_port" ] && port_taken_by_other "$PORT_CHOSEN"; then
    die "端口 ${PORT_CHOSEN} 已经有别的程序在用。请换一个，例如 PORT=8080"
  fi
  USER_CHOSEN=${WEB_USER:-$(config_get user 2>/dev/null || old_config_get username 2>/dev/null || printf '%s' admin)}
  [ "$(user_text_problem "$USER_CHOSEN")" = ok ] || die "登录名字只能用英文字母和数字（WEB_USER）。"
  if [ -n "${WEB_PASS:-}" ]; then
    [ "$(pass_text_problem "$WEB_PASS")" = ok ] || die "WEB_PASS 至少 6 位，不能有空格。"
    PASS_MODE=custom
    PASS_CHOSEN=$WEB_PASS
  elif [ -n "$(config_get pass_hash 2>/dev/null || true)" ]; then
    PASS_MODE=keep
    PASS_CHOSEN=$(read_saved_password 2>/dev/null || true)
  else
    PASS_CHOSEN=$(read_saved_password "$OLD_NOTE" 2>/dev/null || true)
    if [ -n "$PASS_CHOSEN" ] && [ "$(pass_text_problem "$PASS_CHOSEN")" = ok ]; then
      PASS_MODE=custom
    else
      PASS_MODE=random
      PASS_CHOSEN=
    fi
  fi
  OPEN_CHOSEN=${OPEN:-$(config_get open_mode 2>/dev/null || printf '%s' 1)}
  [ "$OPEN_CHOSEN" = 2 ] || OPEN_CHOSEN=1
  WARP_CHOSEN=$(yes_value "${WARP:-$(config_get warp 2>/dev/null || printf '%s' 1)}" 1)
  say_ok "全自动模式：端口 ${PORT_CHOSEN}，登录名字 ${USER_CHOSEN}，不再提问"
}

#----------------------------------------------------------------------
# 装好以后，告诉你怎么在 Mac 上用。
#----------------------------------------------------------------------
print_how_to_use() {
  port=$1
  user=$2
  pass=$3
  open_mode=$4
  title=$5
  collect_addrs
  printf '\n%s\n' "${C_GREEN}${title}${C_NC}"
  if [ "$open_mode" = 2 ]; then
    printf '\n%s\n' "你选了 SSH 转发。每次用之前，在 Mac 的「终端」里执行（地址换成你平时登这台 VPS 用的）："
    printf '%s\n' "  ssh -L ${port}:127.0.0.1:${port} root@你的VPS地址"
    printf '%s\n' "不要关这个终端窗口，然后在 Mac 浏览器打开：http://127.0.0.1:${port}"
  else
    printf '\n%s\n' "在 Mac 浏览器（Safari 或 Chrome）打开："
    if [ -n "$ADDR_PUBLIC" ]; then
      printf '%s\n' "  http://${ADDR_PUBLIC}:${port}"
    else
      printf '%s\n' "  http://你的VPS的IP:${port}"
    fi
    if [ -n "$ADDR_V6" ]; then
      printf '%s\n' "  （也可以用 IPv6：http://[${ADDR_V6}]:${port}）"
    fi
    if [ -z "$ADDR_V4" ] && [ -n "$ADDR_V4_PRIVATE" ]; then
      printf '%s\n' "这台 VPS 本机只有内网地址 ${ADDR_V4_PRIVATE}。上面的网址打不开时，"
      printf '%s\n' "请在服务商面板把外网端口 ${port} 映射到这台 VPS 的 ${port}，或者重新运行 ytdlp-web 选 SSH 转发。"
    fi
  fi
  printf '\n%s\n' "怎么用："
  printf '%s\n' "  1. 登录后，把视频链接粘贴到框里，点「开始」。"
  printf '%s\n' "     支持 YouTube、抖音、小红书、B站、TikTok、推特、IG，可以直接粘 App 里复制的整段分享文字。"
  printf '%s\n' "  2. 等进度走完，视频（或图片）会自动存进 Mac 的「下载」文件夹。"
  printf '%s\n' "     Safari 第一次会问「是否允许下载」，点「允许」。"
  printf '%s\n' "  3. 传完以后 VPS 上的文件会自动删掉，不用管。"
  printf '%s\n' "  被网站拦住时，网页会自动换办法（IPv6/IPv4、WARP 等）；实在不行会用中文告诉你上传哪个平台的 cookies。"
  printf '\n%s\n' "以后再运行一次安装命令，或者输入 ytdlp-web ，直接回车就是更新到最新版本。"
  printf '%s\n' "查看：ytdlp-web --status    运行记录：ytdlp-web --log    换密码：ytdlp-web --reset-password    卸载：ytdlp-web --uninstall"
  # 最后醒目地印出：网址、登录名、密码。
  if [ "$open_mode" = 2 ]; then
    url="http://127.0.0.1:${port}  （先在 Mac 终端执行 ssh -L ${port}:127.0.0.1:${port} root@你的VPS地址）"
  elif [ -n "$ADDR_PUBLIC" ]; then
    url="http://${ADDR_PUBLIC}:${port}"
  else
    url="http://你的VPS的IP:${port}"
  fi
  [ -n "$pass" ] || pass="还是原来那把（忘了就运行 ytdlp-web --reset-password）"
  printf '\n%s\n' "${C_GREEN}==================== 记下这三样 ====================${C_NC}"
  printf '%s\n' "${C_GREEN}  网址：  ${url}${C_NC}"
  printf '%s\n' "${C_GREEN}  登录名：${user}${C_NC}"
  printf '%s\n' "${C_GREEN}  密码：  ${pass}${C_NC}"
  printf '%s\n' "${C_GREEN}=====================================================${C_NC}"
  printf '%s\n' "（也记在 $NOTE_FILE ，忘了就输入：ytdlp-web --status）"
}

#----------------------------------------------------------------------
# 安装 / 更新的总流程。
#----------------------------------------------------------------------
do_install() {
  detect_machine
  say_step "这台 VPS"
  say_info "系统：$OS_PRETTY"
  say_info "包管理：${PM}    架构：${ARCH}    系统库：${LIBC}    启动：${INIT}"
  say_info "内存：${MEM_MB:-未知}MB    已有虚拟内存：${SWAP_MB}MB    磁盘剩余：${DISK_MB}MB    CPU：${NCPU}"
  ytdlp_asset "$ARCH" "$LIBC" >/dev/null || die "没有适合 $ARCH / $LIBC 的 yt-dlp，这台机器装不了。"

  UPDATE_MODE=0
  MIGRATE=0
  asked=0
  if auto_mode; then
    if install_ready; then
      UPDATE_MODE=1
    elif old_install_present; then
      MIGRATE=1
    fi
    load_auto_choices
    asked=1
  elif install_ready; then
    say_step "这台 VPS 已经装过了"
    printf '%s\n' "再运行一次，就是把所有程序更新到最新版本。端口、密码都保持不变。"
    printf '%s\n' "  1) 更新到最新版本（推荐）"
    printf '%s\n' "  2) 我想改端口、密码或其他设置"
    ask_menu UPDATE_CHOICE 1 2
    if [ "$UPDATE_CHOICE" = 1 ]; then
      if load_saved_choices; then
        UPDATE_MODE=1
        asked=1
        say_ok "按原来的设置更新。端口 ${PORT_CHOSEN}"
      else
        say_warn "原来的设置读不全，请再答一遍。"
      fi
    fi
  elif old_install_present; then
    MIGRATE=1
    say_step "这台 VPS 装的是旧版"
    printf '%s\n' "旧版是先把视频下到 VPS，你再自己存回 Mac。"
    printf '%s\n' "新版：贴链接以后视频自动存进 Mac 的「下载」文件夹，VPS 上自动删掉。"
    printf '%s\n' "  1) 升级到新版，端口和密码不变（推荐）"
    printf '%s\n' "  2) 升级到新版，重新回答问题"
    ask_menu MIGRATE_CHOICE 1 2
    if [ "$MIGRATE_CHOICE" = 1 ] && load_old_choices; then
      asked=1
      say_ok "沿用旧版的端口 ${PORT_CHOSEN} 和登录名字 ${USER_CHOSEN}"
    fi
  fi
  if [ "$asked" != 1 ]; then
    while true; do
      ask_settings 0
      show_plan
      ask_menu PLAN_OK 1 2
      [ "$PLAN_OK" = 1 ] && break
      printf '%s\n' "好，我们再答一遍。"
    done
  fi

  say_step "准备内存和基础工具"
  prepare_workdir
  prepare_memory
  ensure_tool ca || say_warn "证书包没装上，后面下载可能会失败"
  # 有 curl 最好（WARP 测试要用）。只有 BusyBox 的 wget 时，试着从软件源补一个 curl。
  if ! have curl; then
    pm_install_one curl >/dev/null 2>&1 || true
  fi
  ensure_tool curl || die "装不上 curl 或 wget，没法下载程序。"
  ensure_tool tar || die "装不上 tar。"
  # 网页服务是 Perl 写的。Debian / Ubuntu 一定自带，别的系统从软件源装。
  ensure_tool perl || die "装不上 Perl（网页服务要用）。"
  ensure_tool unzip >/dev/null 2>&1 || true

  ensure_ffmpeg
  install_qjs
  install_ytdlp
  install_pot
  install_warp

  # 密码：继续用、自己设或者随机生成。
  user=$USER_CHOSEN
  hash=
  if [ "$PASS_MODE" = keep ]; then
    pass=$PASS_CHOSEN
    hash=$(config_get pass_hash 2>/dev/null || true)
    [ -n "$hash" ] || die "原来的密码记录坏了。请运行 ytdlp-web --reset-password 换一把。"
  elif [ "$PASS_MODE" = custom ]; then
    pass=$PASS_CHOSEN
  else
    pass=$(rand_hex 6) || die "随机密码没生成。"
  fi
  if [ -z "$hash" ]; then
    hash=$(hash_password "$pass") || die "登录密码没能生成。没有登录不能把网页放到网上。"
  fi

  say_step "放好网页服务"
  # 有视频正在下载时，先等它下完再重启，不打断。
  wait_for_idle
  stop_service
  [ "$MIGRATE" = 1 ] && stop_old_service
  write_server
  write_plugin
  mkdir -p "$CONF_DIR" "$DATA"
  chmod 700 "$CONF_DIR"
  ff=$(command -v ffmpeg 2>/dev/null || true)
  [ -n "$JS_RUNTIME" ] || JS_RUNTIME=$(js_runtime_value quickjs /usr/local/bin/qjs)
  port=$PORT_CHOSEN
  write_config "$CONF_FILE" "$port" "$(listen_for_open "$OPEN_CHOSEN")" "$user" "$hash" "$DATA" \
    /usr/local/bin/yt-dlp "$JS_RUNTIME" "$ff" "${POT_BIN:-}" "${WARP_CONF:-}" "${WARP_PORT:-40000}" "$OPEN_CHOSEN" "$WARP_CHOSEN"
  chmod 600 "$CONF_FILE"
  # 换了密码，以前登录过的浏览器都要重新登录。
  if [ "$PASS_MODE" != keep ]; then
    rm -f "$DATA/state/sessions"
  fi
  [ -n "$pass" ] && write_install_note "$user" "$pass" "$port"
  write_runner
  write_service
  install_cli
  if [ "$OPEN_CHOSEN" = 1 ]; then
    open_firewall "$port"
  else
    say_info "按你的选择，网页只在 VPS 本机能打开，没有放到公网。"
  fi

  say_step "启动"
  upgrade_flag_clear
  start_service || true
  if ! health_ok "$port"; then
    show_fail_log
    die "网页没能在端口 $port 上打开。把上面的记录发给懂的人看看。"
  fi
  say_ok "网页已在端口 ${port} 运行"
  [ "$MIGRATE" = 1 ] && remove_old_install
  rm -rf "$WORK"
  if [ "$UPDATE_MODE" = 1 ]; then
    print_how_to_use "$port" "$user" "$pass" "$OPEN_CHOSEN" "更新好了。程序都换成了最新版本，端口和密码没变。"
  else
    print_how_to_use "$port" "$user" "$pass" "$OPEN_CHOSEN" "装好了。"
  fi
}

# 只换密码，别的都不动。
reset_password_only() {
  detect_machine
  install_ready || die "还没装好，先运行 ytdlp-web 安装。"
  load_saved_choices || die "原来的设置读不全，请运行 ytdlp-web 选第 2 项重新设置。"
  ask_password 1
  if [ "$PASS_MODE" = random ]; then
    pass=$(rand_hex 6) || die "随机密码没生成。"
  else
    pass=$PASS_CHOSEN
  fi
  hash=$(hash_password "$pass") || die "密码没能生成。"
  tmp=$CONF_FILE.new
  awk -v h="$hash" 'BEGIN{done=0} /^pass_hash=/{print "pass_hash=" h; done=1; next} {print} END{if(!done) print "pass_hash=" h}' "$CONF_FILE" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$CONF_FILE"
  write_install_note "$USER_CHOSEN" "$pass" "$PORT_CHOSEN"
  # 先等正在下的视频下完（等的时候网页还能用），再让旧登录失效、重启。
  wait_for_idle
  rm -f "$DATA/state/sessions"
  stop_service
  upgrade_flag_clear
  start_service || true
  health_ok "$PORT_CHOSEN" || { show_fail_log; die "网页没能重新启动。"; }
  say_ok "密码换好了。登录名字：${USER_CHOSEN}    新密码：${pass}"
  printf '%s\n' "以前登录过的浏览器需要用新密码重新登录。"
}

usage() {
  printf '%s\n' "用法："
  printf '%s\n' "  ytdlp-web                   第一次安装会问几个问题。已经装过再运行，直接回车就是更新到最新版本"
  printf '%s\n' "  ytdlp-web --status          查看装得怎么样、网址和密码"
  printf '%s\n' "  ytdlp-web --log             查看最近的运行记录"
  printf '%s\n' "  ytdlp-web --reset-password  换一把登录密码"
  printf '%s\n' "  ytdlp-web --uninstall       卸载"
}

main() {
  action=install
  for arg in "$@"; do
    case "$arg" in
      --status|-s) action=status ;;
      --log|--logs) action=log ;;
      --uninstall) action=uninstall ;;
      --reset-password) action=reset ;;
      --help|-h) usage; exit 0 ;;
      *) die "不认识的参数：$arg" ;;
    esac
  done
  case "$(uname -s)" in
    Linux) ;;
    *) die "这个脚本要在 Linux VPS 上运行。你现在是 $(uname -s)。Mac 上不用装任何东西，用浏览器打开 VPS 的网页就行。" ;;
  esac
  if [ "$(id -u)" -ne 0 ]; then
    die "请用 root 运行。可以先输入：sudo -i"
  fi
  case "$action" in
    status) print_status; exit 0 ;;
    log) print_log 80; exit 0 ;;
  esac
  # 下面这些会改系统，同一时间只能跑一份。
  lock_or_quit
  prepare_stdin
  maybe_self_update "$@"
  case "$action" in
    uninstall) uninstall_all ;;
    reset) reset_password_only ;;
    install) do_install ;;
  esac
}

if [ "${YTD_TEST:-}" != 1 ]; then
  main "$@"
fi
