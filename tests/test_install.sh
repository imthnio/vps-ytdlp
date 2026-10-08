#!/bin/sh
# 只测 install.sh 里的判断，不碰系统、不下载。
# 用法：sh tests/test_install.sh
cd "$(dirname "$0")/.." || exit 1
YTD_TEST=1
# shellcheck disable=SC1091
. ./install.sh

fail=0
check() {
  name=$1
  got=$2
  want=$3
  if [ "$got" = "$want" ]; then
    printf 'ok %s\n' "$name"
  else
    printf 'FAIL %s\n got [%s]\n want [%s]\n' "$name" "$got" "$want" >&2
    fail=1
  fi
}
yes_no() {
  name=$1
  shift
  if "$@" >/dev/null 2>&1; then got=yes; else got=no; fi
  printf '%s' "$got"
}

# 架构和下载文件名
check arch-amd64 "$(arch_from_uname x86_64)" amd64
check arch-arm64 "$(arch_from_uname aarch64)" arm64
check arch-armv7 "$(arch_from_uname armv7l)" armv7
check arch-386 "$(arch_from_uname i686)" 386
check arch-unknown "$(yes_no x arch_from_uname ppc64le)" no
check ytdlp-glibc "$(ytdlp_asset amd64 glibc)" yt-dlp_linux
check ytdlp-musl "$(ytdlp_asset amd64 musl)" yt-dlp_musllinux
check ytdlp-arm64-musl "$(ytdlp_asset arm64 musl)" yt-dlp_musllinux_aarch64
check ytdlp-armv7 "$(ytdlp_asset armv7 glibc)" yt-dlp_linux_armv7l.zip
check qjs-amd64 "$(qjs_asset amd64)" qjs-linux-x86_64
check qjs-arm "$(qjs_asset arm64)" qjs-linux-aarch64
check pot-amd64 "$(pot_asset amd64 glibc)" bgutil-pot-linux-x86_64
check pot-arm64 "$(pot_asset arm64 glibc)" bgutil-pot-linux-aarch64
check pot-musl "$(yes_no x pot_asset amd64 musl)" no
check pot-armv7 "$(yes_no x pot_asset armv7 glibc)" no
check wgcf-amd64 "$(wgcf_asset 2.3.0 amd64)" wgcf_2.3.0_linux_amd64
check wgcf-armv7 "$(wgcf_asset 2.3.0 armv7)" wgcf_2.3.0_linux_armv7
check wireproxy-amd64 "$(wireproxy_asset amd64)" wireproxy_linux_amd64.tar.gz
check wireproxy-arm "$(wireproxy_asset armv7)" wireproxy_linux_arm.tar.gz
check other-libc "$(other_libc glibc)" musl

# PO 令牌程序：内存加虚拟内存够 300MB、64 位、glibc 才装
check pot-384 "$(yes_no x pot_wanted amd64 glibc 384 0)" yes
check pot-64-swap "$(yes_no x pot_wanted amd64 glibc 64 704)" yes
check pot-64-noswap "$(yes_no x pot_wanted amd64 glibc 64 128)" no
check pot-musl-big "$(yes_no x pot_wanted amd64 musl 2048 0)" no
check pot-bad-mem "$(yes_no x pot_wanted amd64 glibc '' 0)" no

# 虚拟内存怎么配
check swap-64-big "$(swap_plan_mb 64 0 5000)" 704
check swap-64-tight "$(swap_plan_mb 64 0 300)" 128
check swap-64-tiny "$(swap_plan_mb 64 0 200)" 0
check swap-already "$(swap_plan_mb 64 700 5000)" 0
check swap-384 "$(swap_plan_mb 384 0 100000)" 384
check swap-512 "$(swap_plan_mb 512 0 2000)" 256
check swap-768 "$(swap_plan_mb 768 0 5000)" 0
check swap-bad "$(swap_plan_mb abc 0 5000)" 0

check data-disk "$(data_dir_for ext4)" /var/lib/ytdlp-web
check data-tmpfs "$(data_dir_for tmpfs)" /ytdlp-web-data
check work-tmpfs "$(workdir_for tmpfs 500)" /ytdlp-web-work
check work-small "$(workdir_for ext4 40)" /ytdlp-web-work
check work-ok "$(workdir_for ext4 2000)" /tmp/ytdlp-web-work

# 认系统、包名
check pm-debian "$(pm_from_release debian 'debian')" apt
check pm-ubuntu "$(pm_from_release ubuntu debian)" apt
check pm-alpine "$(pm_from_release alpine '')" apk
check pm-centos "$(pm_from_release centos 'centos rhel fedora')" dnf
check pm-arch "$(pm_from_release arch '')" pacman
check pm-suse "$(pm_from_release opensuse-leap suse)" zypper
check pm-owrt "$(pm_from_release openwrt '')" opkg
check pkg-apt-ffmpeg "$(pkg_name apt ffmpeg)" ffmpeg
check pkg-apt-xz "$(pkg_name apt xz)" xz-utils
check pkg-apk-xz "$(pkg_name apk xz)" xz
check pkg-apt-perl "$(pkg_name apt perl)" perl-base
check pkg-apk-perl "$(pkg_name apk perl)" perl
check pkg-owrt-perl "$(pkg_name opkg perl | cut -d' ' -f1)" perl
check pkg-htpasswd-gone "$(yes_no x pkg_name apt htpasswd)" no

check libc-musl "$(libc_from_text 'ld-musl-x86_64.so.1')" musl
check libc-glibc "$(libc_from_text 'libc.so.6')" glibc
check js "$(js_runtime_value quickjs /usr/local/bin/qjs)" "quickjs:/usr/local/bin/qjs"

# IP 判断
check private-yes "$(yes_no x is_private_ipv4 10.91.0.13)" yes
check private-cgnat "$(yes_no x is_private_ipv4 100.64.0.1)" yes
check private-192 "$(yes_no x is_private_ipv4 192.168.1.1)" yes
check public-ip "$(yes_no x is_private_ipv4 150.129.9.164)" no
check ipv4-ok "$(yes_no x is_ipv4 1.2.3.4)" yes
check ipv4-short "$(yes_no x is_ipv4 1.2.3)" no
check v6-global "$(yes_no x is_global_ipv6 2001:db8::1)" yes
check v6-link "$(yes_no x is_global_ipv6 fe80::1)" no
check v6-ula "$(yes_no x is_global_ipv6 fd00::1)" no

# 版本号和自我更新的检查
check newer "$(yes_no x version_newer 2.0.1 2.0.0)" yes
check newer-equal "$(yes_no x version_newer 2.0.0 2.0.0)" no
check newer-major "$(yes_no x version_newer 2.0.0 1.9.9)" yes
check ver-file "$(version_from_file ./install.sh)" "$VERSION"
check ver-221 "$VERSION" 2.2.1
check mem-gate "$(grep -c '可用内存不到 384MB' install.sh || true)" 0
check newer-211 "$(yes_no x version_newer 2.1.1 2.1.0)" yes
# 网页服务里的版本号要和脚本一致（网页 /health 会显示它）
check ver-server "$(sed -n "s/^my \$VERSION = '\(.*\)';/\1/p" install.sh)" "$VERSION"
# 装完/更新完印出来的「怎么用」是通用说法，不再只说 YouTube
usage=$( collect_addrs() { :; }; print_how_to_use 15346 admin pw 2 '装好了' 2>&1 )
case "$usage" in *'把视频链接粘贴到框里'*'抖音、小红书、B站、TikTok、推特、IG'*'整段分享文字'*) check usage-generic yes yes ;; *) check usage-generic "$usage" generic ;; esac
case "$usage" in *'把 YouTube 视频链接'*) check usage-no-yt-only bad ok ;; *) check usage-no-yt-only ok ok ;; esac
check script-marker "$(yes_no x remote_script_ok ./install.sh)" yes
tmpd=$(mktemp -d)
printf '<html>404</html>\n' > "$tmpd/bad.sh"
check script-html "$(yes_no x remote_script_ok "$tmpd/bad.sh")" no

# 输入检查
check port-ok "$(port_text_problem 15346)" ok
check port-ssh "$(port_text_problem 22)" ssh
check port-big "$(port_text_problem 70000)" range
check port-zero "$(port_text_problem 0)" range
check port-text "$(port_text_problem abc)" nan
check port-lead0 "$(normalize_port 08080)" 8080
check port-default-none "$(yes_no x port_prompt_default '')" no
check port-default-ok "$(port_prompt_default 3033)" 3033
check user-ok "$(user_text_problem admin)" ok
check user-chars "$(user_text_problem 'ad min')" chars
check pass-ok "$(pass_text_problem abc123)" ok
check pass-short "$(pass_text_problem abc)" short
check pass-space "$(pass_text_problem 'abc 1234')" space
check menu-enter "$(menu_answer '' 1 2)" 1
check menu-2 "$(menu_answer ' 2 ' 1 2)" 2
check menu-bad "$(menu_answer 3 1 2)" bad
check menu-text "$(menu_answer x 1 2)" bad
check open-1 "$(listen_for_open 1)" 0.0.0.0
check open-2 "$(listen_for_open 2)" 127.0.0.1

# 新配置文件：写进去、读出来
cfg=$tmpd/web.conf
write_config "$cfg" 15346 0.0.0.0 admin '$6$salt$abc/DEF.ghi' /var/lib/ytdlp-web /usr/local/bin/yt-dlp \
  'quickjs:/usr/local/bin/qjs' /usr/bin/ffmpeg /usr/local/bin/bgutil-pot /etc/ytdlp-web/warp/wireproxy.conf 40001 1 1
check cfg-port "$(config_get port "$cfg")" 15346
check cfg-listen "$(config_get listen "$cfg")" 0.0.0.0
check cfg-user "$(config_get user "$cfg")" admin
check cfg-hash "$(config_get pass_hash "$cfg")" '$6$salt$abc/DEF.ghi'
check cfg-js "$(config_get js "$cfg")" 'quickjs:/usr/local/bin/qjs'
check cfg-pot "$(config_get pot "$cfg")" /usr/local/bin/bgutil-pot
check cfg-potdir "$(config_get pot_plugins "$cfg")" /usr/local/lib/ytdlp-web/pot-plugins
check cfg-plugins "$(config_get plugins "$cfg")" /usr/local/lib/ytdlp-web/plugins
check cfg-wireproxy "$(config_get wireproxy "$cfg")" /usr/local/bin/wireproxy
check cfg-warp-port "$(config_get warp_port "$cfg")" 40001
check cfg-warp "$(config_get warp "$cfg")" 1
write_config "$cfg" 8080 127.0.0.1 admin '$6$salt$abc' /var/lib/ytdlp-web /usr/local/bin/yt-dlp '' '' '' '' '' 2 0
check cfg-nopot "$(yes_no x config_get pot "$cfg")" no
check cfg-nowarp "$(yes_no x config_get wireproxy "$cfg")" no
check cfg-warp-default "$(config_get warp_port "$cfg")" 40000
check cfg-open2 "$(config_get open_mode "$cfg")" 2
check cfg-missing-hash "$(yes_no x write_config "$cfg" 8080 0.0.0.0 admin '')" no

# 装过没有
srv=$tmpd/server.pl
: > "$srv"
write_config "$cfg" 15346 0.0.0.0 admin '$6$salt$abc' /var/lib/ytdlp-web /usr/local/bin/yt-dlp '' '' '' '' '' 1 1
check ready-yes "$(SERVER_FILE=$srv CONF_FILE=$cfg; yes_no x install_ready)" yes
check ready-noserver "$(SERVER_FILE=$tmpd/none CONF_FILE=$cfg; yes_no x install_ready)" no
sed 's/^pass_hash=.*/pass_hash=plain/' "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg"
check ready-badhash "$(SERVER_FILE=$srv CONF_FILE=$cfg; yes_no x install_ready)" no
write_config "$cfg" 15346 127.0.0.1 xiaoming '$6$salt$abc' /var/lib/ytdlp-web /usr/local/bin/yt-dlp '' '' '' '' '' 2 0
printf 'username=xiaoming\npassword=SecretPw1\nport=15346\n' > "$tmpd/note"
(
  CONF_FILE=$cfg NOTE_FILE=$tmpd/note
  load_saved_choices
  check saved-port "$PORT_CHOSEN" 15346
  check saved-user "$USER_CHOSEN" xiaoming
  check saved-pass "$PASS_CHOSEN" SecretPw1
  check saved-mode "$PASS_MODE" keep
  check saved-open "$OPEN_CHOSEN" 2
  check saved-warp "$WARP_CHOSEN" 0
) || fail=1

# 从旧版（1.x）升级：读 YAML 里的端口和名字、install.txt 里的密码
cat > "$tmpd/old.yml" <<'EOF'
server:
  host: "0.0.0.0"
  port: 3033
  queue_size: 1
paths:
  download_path: "/var/lib/yt-dlp-webui/downloads"
authentication:
  require_auth: true
  username: "admin"
  password_hash: "$2y$05$abc"
EOF
printf 'username=admin\npassword=OldPass99\nport=3033\n' > "$tmpd/old.txt"
check old-port "$(old_config_get port "$tmpd/old.yml")" 3033
check old-user "$(old_config_get username "$tmpd/old.yml")" admin
check old-path "$(old_config_get download_path "$tmpd/old.yml")" /var/lib/yt-dlp-webui/downloads
(
  OLD_CONF=$tmpd/old.yml OLD_NOTE=$tmpd/old.txt
  check old-present "$(yes_no x old_install_present)" yes
  load_old_choices
  check old-load-port "$PORT_CHOSEN" 3033
  check old-load-user "$USER_CHOSEN" admin
  check old-load-pass "$PASS_CHOSEN" OldPass99
  check old-load-mode "$PASS_MODE" custom
  check old-load-warp "$WARP_CHOSEN" 1
  OLD_NOTE=$tmpd/none
  load_old_choices
  check old-nopass-mode "$PASS_MODE" random
) || fail=1

# 全自动模式：PORT=端口 就不再提问
check auto-off "$(PORT='' YTD_PORT='' YTD_AUTO=''; yes_no x auto_mode)" no
check auto-port "$(PORT=15346; yes_no x auto_mode)" yes
check yes-value "$(yes_value no 1)$(yes_value 1 0)$(yes_value '' 1)" 011
(
  CONF_FILE=$tmpd/none.conf NOTE_FILE=$tmpd/none OLD_CONF=$tmpd/none OLD_NOTE=$tmpd/none MIGRATE=0
  port_taken_by_other() { return 1; }
  PORT=15346 WEB_USER='' WEB_PASS='' OPEN='' WARP=0
  load_auto_choices >/dev/null
  check auto-load-port "$PORT_CHOSEN" 15346
  check auto-load-user "$USER_CHOSEN" admin
  check auto-load-pass "$PASS_MODE" random
  check auto-load-open "$OPEN_CHOSEN" 1
  check auto-load-warp "$WARP_CHOSEN" 0
  WEB_PASS=Secret123 OPEN=2 WARP=
  load_auto_choices >/dev/null
  check auto-custom-pass "$PASS_MODE:$PASS_CHOSEN" custom:Secret123
  check auto-open2 "$OPEN_CHOSEN" 2
  check auto-warp-default "$WARP_CHOSEN" 1
) || fail=1
check auto-bad-port "$(PORT=22; CONF_FILE=$tmpd/none.conf OLD_CONF=$tmpd/none; (load_auto_choices) >/dev/null 2>&1 && echo yes || echo no)" no

# 同一时间只能跑一份：mkdir 锁 + 进程号
LOCK_DIR=$tmpd/lock
if lock_try; then got=yes; else got=no; fi
check lock-get "$got" yes
check lock-pid "$(cat "$LOCK_DIR/pid")" "$$"
check lock-again-self "$(yes_no x lock_try)" yes
other=$(YTD_TEST=1 YTD_LOCK_DIR=$LOCK_DIR sh -c '. ./install.sh; if lock_try; then echo got; else echo "busy $LOCK_OTHER"; fi')
check lock-other-busy "$other" "busy $$"
msg=$(YTD_TEST=1 YTD_LOCK_DIR=$LOCK_DIR sh -c '. ./install.sh; lock_or_quit; echo should-not-run' 2>&1)
has_msg=no
case "$msg" in *"已经有一个安装在进行（进程号 $$），等它结束再运行"*) has_msg=yes ;; esac
check lock-quit-msg "$has_msg" yes
check lock-quit-norun "$(printf '%s' "$msg" | grep -c should-not-run)" 0
lock_release
check lock-release "$(yes_no x test -d "$LOCK_DIR")" no
# 残留：锁里的进程已经不在了，自动清掉
mkdir "$LOCK_DIR" && printf '999999\n' > "$LOCK_DIR/pid"
if lock_try; then got=yes; else got=no; fi
check lock-stale "$got" yes
check lock-stale-pid "$(cat "$LOCK_DIR/pid")" "$$"
lock_release
# 残留：锁目录里没有进程号
mkdir "$LOCK_DIR"
if lock_try; then got=yes; else got=no; fi
check lock-empty "$got" yes
lock_release
check lock-empty-free "$(yes_no x test -d "$LOCK_DIR")" no
# 正常退出、出错退出、Ctrl+C 都会删锁
YTD_TEST=1 YTD_LOCK_DIR=$LOCK_DIR sh -c '. ./install.sh; lock_or_quit; [ -d "$LOCK_DIR" ] && exit 0; exit 5'
check lock-exit-code "$?" 0
check lock-exit-free "$(yes_no x test -d "$LOCK_DIR")" no
YTD_TEST=1 YTD_LOCK_DIR=$LOCK_DIR sh -c '. ./install.sh; lock_or_quit; die "出错了"' 2>/dev/null
check lock-die-free "$(yes_no x test -d "$LOCK_DIR")" no
YTD_TEST=1 YTD_LOCK_DIR=$LOCK_DIR sh -c '. ./install.sh; lock_or_quit; kill -INT $$; sleep 5; exit 0' >/dev/null 2>&1
check lock-ctrlc-code "$?" 130
check lock-ctrlc-free "$(yes_no x test -d "$LOCK_DIR")" no
YTD_TEST=1 YTD_LOCK_DIR=$LOCK_DIR sh -c '. ./install.sh; lock_or_quit; kill -TERM $$; sleep 5; exit 0' >/dev/null 2>&1
check lock-term-free "$(yes_no x test -d "$LOCK_DIR")" no
# 8 份同时抢锁，只能有 1 份拿到
for i in 1 2 3 4 5 6 7 8; do
  YTD_TEST=1 YTD_LOCK_DIR=$LOCK_DIR sh -c '. ./install.sh; if lock_try; then echo got; sleep 2; lock_release; fi' >> "$tmpd/race" 2>/dev/null &
done
wait
check lock-race "$(grep -c got "$tmpd/race")" 1
check lock-race-free "$(yes_no x test -d "$LOCK_DIR")" no
# 只读的 --status / --log 不拿锁（main 里在它们之后才加锁）
check lock-after-readonly "$(sed -n '/^main() {/,/^}/p' install.sh | awk '/print_log 80/{a=NR} /lock_or_quit/{b=NR} END{print (a && b && a < b) ? "yes" : "no"}')" yes

# apt 被别的程序占着时先等
fp=$tmpd/proc
mkdir -p "$fp/100" "$fp/200"
printf 'bash\n' > "$fp/100/comm"
printf 'unattended-upgr\n' > "$fp/200/comm"
printf '/usr/bin/python3\000/usr/share/unattended-upgrades/unattended-upgrade-shutdown\000--wait-for-signal\000' > "$fp/200/cmdline"
check apt-free "$(YTD_PROC_DIR=$fp; yes_no x apt_busy_pid)" no
mkdir -p "$fp/300"
printf 'dpkg\n' > "$fp/300/comm"
check apt-busy-dpkg "$(YTD_PROC_DIR=$fp apt_busy_pid)" 300
rm -rf "$fp/300"
mkdir -p "$fp/400"
printf 'unattended-upgr\n' > "$fp/400/comm"
printf '/usr/bin/python3\000/usr/bin/unattended-upgrade\000' > "$fp/400/cmdline"
check apt-busy-uu "$(YTD_PROC_DIR=$fp apt_busy_pid)" 400
out=$(YTD_PROC_DIR=$fp YTD_APT_WAIT=2 YTD_APT_STEP=1 wait_apt_free; echo "rc=$?")
check apt-wait-timeout "$(printf '%s' "$out" | grep -c '等了 2 秒')$(printf '%s' "$out" | grep -o 'rc=[0-9]')" "1rc=1"
( sleep 1; rm -rf "$fp/400" ) &
out=$(YTD_PROC_DIR=$fp YTD_APT_WAIT=10 YTD_APT_STEP=1 wait_apt_free; echo "rc=$?")
wait
check apt-wait-done "$(printf '%s' "$out" | grep -c '先等它结束')$(printf '%s' "$out" | grep -c '结束了，继续')$(printf '%s' "$out" | grep -o 'rc=[0-9]')" "11rc=0"
check apt-wait-none "$(YTD_PROC_DIR=$fp YTD_APT_WAIT=10 wait_apt_free; echo "rc=$?")" "rc=0"

# 加一行、删一行 fstab
ft=$tmpd/fstab
printf 'UUID=1 / ext4 defaults 0 1' > "$ft"
fstab_append_line "$ft" '/ytdlp-web.swap none swap sw 0 0'
check fstab-add "$(sed -n 2p "$ft")" '/ytdlp-web.swap none swap sw 0 0'
fstab_append_line "$ft" '/ytdlp-web.swap none swap sw 0 0'
check fstab-once "$(wc -l < "$ft" | tr -d ' ')" 2
fstab_remove_line "$ft" '/ytdlp-web.swap none swap sw 0 0'
check fstab-del "$(cat "$ft")" 'UUID=1 / ext4 defaults 0 1'

check link-sbin "$(shortcut_link_dir /usr/local/sbin:/usr/bin)" ""
check link-bin "$(shortcut_link_dir /usr/bin:/bin)" /usr/bin

# 密码哈希：用 Perl 的 crypt，结果能被网页服务认出来
if command -v perl >/dev/null 2>&1; then
  h=$(hash_password 'abc123')
  case "$h" in
    \$6\$*|\$5\$*|\$1\$*) printf 'ok hash-format\n' ;;
    *) printf 'FAIL hash-format [%s]\n' "$h" >&2; fail=1 ;;
  esac
  again=$(P="abc123" H="$h" perl -e 'print crypt($ENV{P}, $ENV{H}) eq $ENV{H} ? "yes" : "no"')
  check hash-verify "$again" yes
fi

# 内嵌的网页服务：语法对、只用系统自带的模块
sed -n "/<<'YTDLP_WEB_SERVER_EOF'$/,/^YTDLP_WEB_SERVER_EOF$/p" install.sh | sed '1d;$d' > "$tmpd/server.pl"
check server-extracted "$(head -n 1 "$tmpd/server.pl")" '#!/usr/bin/perl'
if command -v perl >/dev/null 2>&1; then
  check server-syntax "$(perl -c "$tmpd/server.pl" 2>&1 | tail -n 1)" "$tmpd/server.pl syntax OK"
  mods=$(sed -n 's/^use \([A-Za-z:]*\).*/\1/p' "$tmpd/server.pl" | sort -u | tr '\n' ' ')
  for m in $mods; do
    case "$m" in
      strict|warnings|utf8|POSIX|Fcntl|IO::Socket::INET|IO::Socket::IP|IO::Select|IO::Handle|File::Path|Socket|Errno) ;;
      *) printf 'FAIL server uses extra module %s\n' "$m" >&2; fail=1 ;;
    esac
  done
  printf 'ok server-modules (%s)\n' "$mods"
fi

# 升级时等正在下载的视频下完再重启
wd=$tmpd/wait
mkjob() {
  mkdir -p "$wd/jobs/$1"
  printf '%s\n' "$2" > "$wd/jobs/$1/status"
}
mkdir -p "$wd/state"
mkjob a 'state=running
title=长视频
pct=42'
mkjob b 'state=queued'
mkdir -p "$wd/jobs/c"
mkjob d 'state=error'
mkjob e "state=done
file=x.mp4
done_at=$(date +%s)"
mkjob f "state=done
file=y.mp4
done_at=$(( $(date +%s) - 3600 ))"
mkjob g "state=done
file=z.mp4
done_at=$(date +%s)"
printf '0 10\n' > "$wd/jobs/g/sent"
sleep 30 &
live=$!
: > "$wd/jobs/f/active.$live"
: > "$wd/jobs/d/active.999999"
check busy-count "$(count_busy "$wd/jobs")" "1 2 1 1"
check busy-lines "$(busy_lines "$wd/jobs")" "    长视频（42%）"
check busy-empty "$(count_busy "$tmpd/nojobs")" "0 0 0 0"
check busy-fresh-old "$(FRESH_SECS=0 count_busy "$wd/jobs")" "1 2 1 0"
kill "$live" 2>/dev/null
wait "$live" 2>/dev/null
check busy-dead-transfer "$(count_busy "$wd/jobs")" "1 2 0 1"
rm -rf "$wd/jobs/e" "$wd/jobs/f" "$wd/jobs/g" "$wd/jobs/d"

# 网页服务没在跑：不用等
waitrun() {
  YTD_TEST=1 CONF_FILE=$tmpd/none.conf DATA=$wd WAIT_SETTLE_SECS=0 WAIT_STEP_SECS=1 "$@"
}
out=$(waitrun sh -c '. ./install.sh; wait_for_idle; echo end' 2>&1)
check wait-no-server "$out" end
# 网页服务在跑，正在下的 2 秒后下完：要等，要说人话，要挂牌子，等完撤牌子
# 假的网页服务：一个不是本脚本子进程的 sleep（停掉以后不会留下僵尸进程）
srv=$(sh -c 'sleep 60 >/dev/null 2>&1 & echo $!')
printf '%s\n' "$srv" > "$wd/state/server.pid"
( sleep 2; printf 'state=done\nfile=x.mp4\ndone_at=1\n' > "$wd/jobs/a/status" ) &
flip=$!
out=$(waitrun sh -c '. ./install.sh; wait_for_idle; [ -f "$DATA/state/upgrading" ] && echo flag=$(cat "$DATA/state/upgrading") me=$$; upgrade_flag_clear; [ -f "$DATA/state/upgrading" ] || echo cleared' 2>&1)
wait "$flip"
case "$out" in *'有 1 个视频正在下载，等它们下完再重启……'*) w=yes ;; *) w=no ;; esac
check wait-msg "$w" yes
case "$out" in *'另外 2 个排队的先等着'*) w=yes ;; *) w=no ;; esac
check wait-queued-msg "$w" yes
case "$out" in *'长视频（42%）'*) w=yes ;; *) w=no ;; esac
check wait-progress "$w" yes
case "$out" in *'按 Ctrl+C'*'FORCE_RESTART=1'*) w=yes ;; *) w=no ;; esac
check wait-skip-hint "$w" yes
case "$out" in *'都下完了'*) w=yes ;; *) w=no ;; esac
check wait-done "$w" yes
check wait-flag-pid "$(printf '%s\n' "$out" | sed -n 's/^flag=\([0-9]*\) me=\([0-9]*\)$/\1=\2/p' | awk -F= '{print ($1 == $2) ? "same" : "diff"}')" same
case "$out" in *cleared*) w=yes ;; *) w=no ;; esac
check wait-flag-cleared "$w" yes
# 退出时（包括出错退出）自动撤牌子
printf 'state=running\n' > "$wd/jobs/a/status"
YTD_LOCK_DIR=$tmpd/lk FORCE_RESTART=0 WAIT_MAX_SECS=0 waitrun sh -c '. ./install.sh; lock_or_quit; wait_for_idle; die "出错了"' >/dev/null 2>&1
check wait-flag-exit "$(yes_no x test -e "$wd/state/upgrading")" no
check wait-lock-exit "$(yes_no x test -e "$tmpd/lk")" no
# 一直下不完：等到上限就不等了
start=$(date +%s)
out=$(WAIT_MAX_SECS=2 waitrun sh -c '. ./install.sh; wait_for_idle; echo end' 2>&1)
case "$out" in *'还没下完，先重启'*end) w=yes ;; *) w=no ;; esac
check wait-timeout "$w" yes
check wait-timeout-fast "$(( $(date +%s) - start < 10 ))" 1
rm -f "$wd/state/upgrading"
# FORCE_RESTART=1：完全不等，也不挂牌子
out=$(FORCE_RESTART=1 waitrun sh -c '. ./install.sh; wait_for_idle; echo end' 2>&1)
case "$out" in *FORCE_RESTART=1*end) w=yes ;; *) w=no ;; esac
check wait-force "$w" yes
check wait-force-noflag "$(yes_no x test -e "$wd/state/upgrading")" no
# 等的时候按 Ctrl+C：不等了，安装接着往下做（不是整个退出）
out=$(YTD_LOCK_DIR=$tmpd/lk2 WAIT_MAX_SECS=60 waitrun sh -c '. ./install.sh; lock_or_quit; ( sleep 2; kill -INT $$ ) & wait_for_idle; echo after-wait; kill -INT $$; sleep 3; echo not-here' 2>&1)
case "$out" in *'不等了，马上重启'*after-wait*) w=yes ;; *) w=no ;; esac
check wait-ctrl-c "$w" yes
case "$out" in *not-here*) w=no ;; *) w=yes ;; esac
check wait-ctrl-c-restores-trap "$w" yes
check wait-ctrl-c-lock "$(yes_no x test -e "$tmpd/lk2")" no
# 网页服务在等的时候自己停了：不再等
( sleep 2; kill "$srv" ) &
flip=$!
out=$(WAIT_MAX_SECS=60 waitrun sh -c '. ./install.sh; wait_for_idle; echo end' 2>&1)
wait "$flip"
case "$out" in *'网页服务自己停了'*end) w=yes ;; *) w=no ;; esac
check wait-server-gone "$w" yes
# 升级流程里，先等再停服务；改密码重启也一样
check wait-before-stop "$(sed -n '/^do_install() {/,/^}/p' install.sh | awk '/wait_for_idle/{a=NR} /stop_service/{if(!b)b=NR} END{print (a && b && a < b) ? "yes" : "no"}')" yes
check wait-before-stop-pw "$(sed -n '/^reset_password_only() {/,/^}/p' install.sh | awk '/wait_for_idle/{a=NR} /stop_service/{if(!b)b=NR} END{print (a && b && a < b) ? "yes" : "no"}')" yes
check flag-clear-before-start "$(sed -n '/^do_install() {/,/^}/p' install.sh | awk '/upgrade_flag_clear/{a=NR} /start_service/{if(!b)b=NR} END{print (a && b && a < b) ? "yes" : "no"}')" yes
# 换 ffmpeg / qjs 时先拷新文件再改名，不直接覆盖正在用的
check ffmpeg-atomic "$(grep -c 'cp "$ff" /usr/local/bin/ffmpeg\|cp "$placed" /usr/local/bin/qjs' install.sh)" 0

rm -rf "$tmpd"
if [ "$fail" -ne 0 ]; then
  printf '\n有测试没通过。\n' >&2
  exit 1
fi
printf '\n全部通过。\n'
