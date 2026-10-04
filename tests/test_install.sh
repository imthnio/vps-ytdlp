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
sed -i 's/^pass_hash=.*/pass_hash=plain/' "$cfg"
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

rm -rf "$tmpd"
if [ "$fail" -ne 0 ]; then
  printf '\n有测试没通过。\n' >&2
  exit 1
fi
printf '\n全部通过。\n'
