#!/bin/sh
# 只测脚本里的判断，不碰系统、不下载。
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

check arch-amd64 "$(arch_from_uname x86_64)" amd64
check arch-arm64 "$(arch_from_uname aarch64)" arm64
check arch-armv7 "$(arch_from_uname armv7l)" armv7
check arch-386 "$(arch_from_uname i686)" 386
if arch_from_uname ppc64le >/dev/null 2>&1; then
  printf 'FAIL arch-unknown should fail\n' >&2
  fail=1
else
  printf 'ok arch-unknown\n'
fi

check webui-amd64 "$(webui_asset amd64)" yt-dlp-webui_linux-amd64
check webui-arm64 "$(webui_asset arm64)" yt-dlp-webui_linux-arm64
if webui_asset 386 >/dev/null 2>&1; then
  printf 'FAIL webui-386 should be missing\n' >&2
  fail=1
else
  printf 'ok webui-386\n'
fi

check ytdlp-glibc "$(ytdlp_asset amd64 glibc)" yt-dlp_linux
check ytdlp-musl "$(ytdlp_asset amd64 musl)" yt-dlp_musllinux
check ytdlp-arm64-musl "$(ytdlp_asset arm64 musl)" yt-dlp_musllinux_aarch64
check ytdlp-armv7 "$(ytdlp_asset armv7 glibc)" yt-dlp_linux_armv7l.zip
check qjs-amd64 "$(qjs_asset amd64)" qjs-linux-x86_64
check qjs-arm "$(qjs_asset arm64)" qjs-linux-aarch64
check other-libc "$(other_libc glibc)" musl

check swap-64-big "$(swap_plan_mb 64 0 5000)" 704
check swap-64-tight "$(swap_plan_mb 64 0 300)" 128
check swap-64-tiny "$(swap_plan_mb 64 0 200)" 0
check swap-already "$(swap_plan_mb 64 700 5000)" 0
check swap-512 "$(swap_plan_mb 512 0 2000)" 256
check swap-768 "$(swap_plan_mb 768 0 5000)" 0
check swap-1024 "$(swap_plan_mb 1024 0 5000)" 0
check swap-bad "$(swap_plan_mb abc 0 5000)" 0

check queue-small "$(queue_for 64)" 1
check queue-big "$(queue_for 1024)" 2
check dl-small "$(downloader_for 64)" /usr/local/bin/yt-dlp-one
check dl-big "$(downloader_for 2048)" /usr/local/bin/yt-dlp
check gomem-64 "$(gomem_for 64)" 48MiB
check gomem-256 "$(gomem_for 256)" 64MiB
check gomem-big "$(gomem_for 2048)" ""

check data-disk "$(data_dir_for ext4)" /var/lib/yt-dlp-webui
check data-tmpfs "$(data_dir_for tmpfs)" /yt-dlp-webui-data
check work-tmpfs "$(workdir_for tmpfs 500)" /yt-dlp-webui-work
check work-small "$(workdir_for ext4 40)" /yt-dlp-webui-work
check work-ok "$(workdir_for ext4 2000)" /tmp/yt-dlp-webui-work

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
check pkg-dnf-htpasswd "$(pkg_name dnf htpasswd)" httpd-tools
check pkg-apt-htpasswd "$(pkg_name apt htpasswd)" apache2-utils

check libc-musl "$(libc_from_text 'ld-musl-x86_64.so.1')" musl
check libc-glibc "$(libc_from_text 'libc.so.6')" glibc
check js "$(js_runtime_value quickjs /usr/local/bin/qjs)" "quickjs:/usr/local/bin/qjs"

if is_private_ipv4 10.1.2.3 && is_private_ipv4 100.64.0.1 && is_private_ipv4 192.168.1.1; then
  printf 'ok private-yes\n'
else
  printf 'FAIL private-yes\n' >&2
  fail=1
fi
if is_private_ipv4 8.8.8.8; then
  printf 'FAIL public should not be private\n' >&2
  fail=1
else
  printf 'ok public-ip\n'
fi
if is_ipv4 1.2.3.4 && ! is_ipv4 1.2.3; then
  printf 'ok ipv4\n'
else
  printf 'FAIL ipv4\n' >&2
  fail=1
fi

check newer "$(version_newer 1.0.1 1.0.0 && printf yes)" yes
if version_newer 1.0.0 1.0.0; then
  printf 'FAIL equal versions are not newer\n' >&2
  fail=1
else
  printf 'ok version-equal\n'
fi
check ver-file "$(version_from_file ./install.sh)" 1.0.3
if remote_script_ok ./install.sh; then
  printf 'ok script-marker\n'
else
  printf 'FAIL script-marker\n' >&2
  fail=1
fi

tmp=$(mktemp)
write_config "$tmp" 3033 admin '$2y$05$abc/DEF.ghi' /usr/local/bin/yt-dlp-one 'quickjs:/usr/local/bin/qjs' 1 /var/lib/yt-dlp-webui
check cfg-port "$(config_get port "$tmp")" 3033
check cfg-user "$(config_get username "$tmp")" admin
check cfg-hash "$(config_get password_hash "$tmp")" '$2y$05$abc/DEF.ghi'
check cfg-js "$(config_get js_runtime_path "$tmp")" 'quickjs:/usr/local/bin/qjs'
check cfg-dl "$(config_get downloader_path "$tmp")" /usr/local/bin/yt-dlp-one
check cfg-dir "$(config_get download_path "$tmp")" /var/lib/yt-dlp-webui/downloads
write_config "$tmp" 8080 admin '$2y$05$abc/DEF.ghi' /usr/local/bin/yt-dlp 'quickjs:/usr/local/bin/qjs' 2 /var/lib/yt-dlp-webui /root/youtube
check cfg-custom-port "$(config_get port "$tmp")" 8080
check cfg-custom-dir "$(config_get download_path "$tmp")" /root/youtube
if grep -q 'SuperSecret' "$tmp"; then
  printf 'FAIL plaintext password leaked\n' >&2
  fail=1
else
  printf 'ok no-plaintext\n'
fi
rm -f "$tmp"

fs=$(mktemp)
printf '%s' 'UUID=abc / ext4 defaults 0 1' > "$fs"
fstab_append_line "$fs" '/yt-dlp-webui.swap none swap sw 0 0'
nl=$(awk 'END {print NR}' "$fs")
check fstab-lines "$nl" 2
last=$(tail -n 1 "$fs")
check fstab-last "$last" '/yt-dlp-webui.swap none swap sw 0 0'
# 再追加一次不能重复
fstab_append_line "$fs" '/yt-dlp-webui.swap none swap sw 0 0'
nl=$(awk 'END {print NR}' "$fs")
check fstab-once "$nl" 2
# 粘在上一行末尾时要拆开
printf '%s' 'UUID=abc / ext4 defaults 0 1/yt-dlp-webui.swap none swap sw 0 0' > "$fs"
fstab_append_line "$fs" '/yt-dlp-webui.swap none swap sw 0 0'
nl=$(awk 'END {print NR}' "$fs")
check fstab-unglue "$nl" 2
fstab_remove_line "$fs" '/yt-dlp-webui.swap none swap sw 0 0'
if grep -q 'yt-dlp-webui.swap' "$fs"; then
  printf 'FAIL fstab remove\n' >&2
  fail=1
else
  printf 'ok fstab-remove\n'
fi
rm -f "$fs"

check port-ok "$(port_text_problem 3033)" ok
check port-pad "$(port_text_problem 03033)" ok
check port-norm "$(normalize_port 03033)" 3033
check port-ssh "$(port_text_problem 22)" ssh
check port-zero "$(port_text_problem 0)" range
check port-big "$(port_text_problem 70000)" range
check port-nan "$(port_text_problem abc)" nan
check user-ok "$(user_text_problem admin)" ok
check user-bad "$(user_text_problem 'xiao ming')" chars
check user-long "$(user_text_problem aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)" len
check pass-ok "$(pass_text_problem abc123)" ok
check pass-short "$(pass_text_problem abc)" short
check pass-space "$(pass_text_problem 'abc 123')" space
check dir-ok "$(dir_text_problem /root/youtube)" ok
check dir-rel "$(dir_text_problem youtube)" relative
check dir-tmp "$(dir_text_problem /tmp/a)" system
check dir-dot "$(dir_text_problem /root/../etc)" dotdot
check dir-quote "$(dir_text_problem '/root/a"b')" symbol
check menu-enter "$(menu_answer '' 1 2)" 1
check menu-space "$(menu_answer ' 2 ' 1 2)" 2
check menu-pad "$(menu_answer 01 1 2)" 1
check menu-bad "$(menu_answer 9 1 2)" bad
check menu-word "$(menu_answer abc 1 2)" bad
check dl-choice1 "$(downloader_for_choice 1)" /usr/local/bin/yt-dlp-one
check dl-choice2 "$(downloader_for_choice 2)" /usr/local/bin/yt-dlp

ask_line "端口题" "3033" ASK_PORT <<EOF
8080
EOF
check ask-port "$ASK_PORT" 8080
ask_line "端口题" "3033" ASK_ENTER <<EOF

EOF
check ask-enter "$ASK_ENTER" 3033
check port-saved "$(port_prompt_default 8080)" 8080
check port-norm-saved "$(port_prompt_default 08080)" 8080
if port_prompt_default "" >/dev/null 2>&1; then
  printf 'FAIL port-no-default should fail\n' >&2
  fail=1
else
  printf 'ok port-no-default\n'
fi
if port_prompt_default 22 >/dev/null 2>&1; then
  printf 'FAIL port-no-ssh should fail\n' >&2
  fail=1
else
  printf 'ok port-no-ssh\n'
fi
ask_menu ASK_MENU 1 2 <<EOF
9
2
EOF
check ask-menu "$ASK_MENU" 2

check queue-keep-big "$(queue_choice_for 2 2048)" 2
check queue-keep-small "$(queue_choice_for 2 64)" 1
check queue-keep-one "$(queue_choice_for 1 2048)" 1
check queue-keep-empty "$(queue_choice_for '' 2048)" 1

ready_dir=$(mktemp -d)
ready_bin=$ready_dir/yt-dlp-webui
ready_cfg=$ready_dir/config.yml
printf '#!/bin/sh\nexit 0\n' > "$ready_bin"
chmod 755 "$ready_bin"
write_config "$ready_cfg" 8080 admin '$2y$05$abc/DEF.ghi' /usr/local/bin/yt-dlp-one 'quickjs:/usr/local/bin/qjs' 1 /var/lib/yt-dlp-webui /root/youtube /usr/local/share/yt-dlp-webui
if grep -q 'frontend_path: "/usr/local/share/yt-dlp-webui"' "$ready_cfg"; then
  printf 'ok cfg-frontend\n'
else
  printf 'FAIL cfg-frontend\n' >&2
  fail=1
fi
YTD_CONFIG_FILE=$ready_cfg
YTD_WEBUI_BIN=$ready_bin
if install_ready; then
  printf 'ok install-ready\n'
else
  printf 'FAIL install-ready\n' >&2
  fail=1
fi
MEM_MB=2048
if load_saved_choices; then
  printf 'ok load-saved\n'
else
  printf 'FAIL load-saved\n' >&2
  fail=1
fi
check saved-port "$PORT_CHOSEN" 8080
check saved-user "$USER_CHOSEN" admin
check saved-dir "$DIR_CHOSEN" /root/youtube
check saved-queue "$QUEUE_CHOSEN" 1
check saved-open "$OPEN_CHOSEN" 0
MEM_MB=64
load_saved_choices
check saved-queue-small "$QUEUE_CHOSEN" 1
# 密码哈希不是 bcrypt 时，不算已经装好，要重新问。
write_config "$ready_cfg" 8080 admin 'not-a-hash' /usr/local/bin/yt-dlp-one 'quickjs:/usr/local/bin/qjs' 2 /var/lib/yt-dlp-webui /root/youtube
if install_ready; then
  printf 'FAIL install-ready-bad-hash should fail\n' >&2
  fail=1
else
  printf 'ok install-ready-bad-hash\n'
fi
rm -f "$ready_bin"
if install_ready; then
  printf 'FAIL install-ready-no-bin should fail\n' >&2
  fail=1
else
  printf 'ok install-ready-no-bin\n'
fi
unset YTD_CONFIG_FILE YTD_WEBUI_BIN MEM_MB
rm -rf "$ready_dir"

if [ "$fail" -eq 0 ]; then
  printf '全部通过\n'
fi
exit "$fail"
