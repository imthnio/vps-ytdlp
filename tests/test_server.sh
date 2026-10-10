#!/bin/sh
# 把 install.sh 里内嵌的网页服务拿出来，配一个假的 yt-dlp 真跑一遍：
# 登录、贴链接、下载到“Mac”、断点续传、传完自动删、被拦换办法、cookies、中文报错，
# 还有多平台：分享文字、抖音/小红书/推特走插件、图文打包 zip、纯文字帖、VP9 转码、存好后自动收起。
# 需要 perl 和 curl。不碰系统，所有东西都在一个临时目录里。
# 用法：sh tests/test_server.sh
cd "$(dirname "$0")/.." || exit 1
command -v perl >/dev/null 2>&1 || { echo "没有 perl，跳过"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "没有 curl，跳过"; exit 0; }

T=$(mktemp -d)
PORT=${TEST_PORT:-18573}
B=http://127.0.0.1:$PORT
fail=0
ok() { printf 'ok %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 got [$2] want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else bad "$1: [$2] 里没有 [$3]"; fi; }

sed -n "/<<'YTDLP_WEB_SERVER_EOF'$/,/^YTDLP_WEB_SERVER_EOF$/p" install.sh | sed '1d;$d' > "$T/server.pl"
hash=$(perl -e 'print crypt("testpass1", "\$6\$testsalt\$")')
mkdir -p "$T/mac" "$T/plugins" "$T/bin"
cp tests/fake-ffmpeg.sh "$T/bin/ffmpeg"
cp tests/fake-ffmpeg.sh "$T/bin/ffprobe"
chmod +x "$T/bin/ffmpeg" "$T/bin/ffprobe"
cat > "$T/web.conf" <<EOF
port=$PORT
listen=127.0.0.1
user=admin
pass_hash=$hash
data=$T/data
ytdlp=$PWD/tests/fake-ytdlp.sh
cookies=$T/cookies.txt
plugins=$T/plugins
ffmpeg=$T/bin/ffmpeg
log=$T/server.log
grace=2
sweep_secs=2
min_free_mb=10
EOF
# 网页服务把记录写到标准错误，和正式安装时一样，接到 server.log。
FAKE_LOG=$T/calls.log perl "$T/server.pl" "$T/web.conf" >> "$T/server.log" 2>&1 &
spid=$!
cleanup() {
  kill "$(cat "$T/data/state/server.pid" 2>/dev/null || echo "$spid")" 2>/dev/null
  sleep 1
  rm -rf "$T"
}
trap cleanup EXIT INT TERM

i=0
until curl -s --noproxy 127.0.0.1 "$B/health" 2>/dev/null | grep -q 'ytdlp-web ok'; do
  i=$((i + 1))
  [ "$i" -gt 50 ] && { cat "$T/server.log"; bad "网页没启动"; exit 1; }
  sleep 0.2
done
ok health

C="curl -s --noproxy 127.0.0.1 -m 20"
J=$T/jar
check no-login "$($C -o /dev/null -w '%{http_code}' "$B/api/jobs")" 401
$C -c "$J" -d 'user=admin&pass=wrong' "$B/login" > "$T/r"
has login-wrong "$(cat "$T/r")" '不对'
check login-ok "$($C -c "$J" -o /dev/null -w '%{http_code}' -d 'user=admin&pass=testpass1' "$B/login")" 302
page=$($C -b "$J" "$B/")
has page "$page" '保存到本地'
has page-start "$page" '开始下载到 VPS'
has page-480 "$page" 'value="p480"'
has page-144 "$page" 'value="p144"'
if printf '%s' "$page" | grep -q '水印\|压缩\|倍速'; then bad page-no-compress; else ok page-no-compress; fi
if printf '%s' "$page" | grep -q '下好以后会自动存到 Mac'; then bad page-no-auto; else ok page-no-auto; fi
check need-header "$($C -b "$J" -o /dev/null -w '%{http_code}' -d 'url=x' "$B/api/add")" 403

add() { $C -b "$J" -H 'X-YTW: 1' --data-urlencode "url=$1" -d "q=${2:-mac}" "$B/api/add"; }
job_id() { sed -n 's/.*"id":"\([0-9a-f]*\)".*/\1/p'; }
# 等任务结束，打印这个任务那一段 JSON
wait_job() {
  n=0
  while [ "$n" -lt 100 ]; do
    js=$($C -b "$J" "$B/api/jobs" | perl -ne 'while(/(\{"[^{}]*?"id":"'"$1"'"[^{}]*\})/g){print $1}')
    case "$js" in
      *'"state":"done"'*|*'"state":"error"'*) printf '%s' "$js"; return 0 ;;
    esac
    n=$((n + 1))
    sleep 0.3
  done
  printf '%s' "$js"
}

has bad-url "$(add 'hello world')" '不像网址'
has playlist "$(add 'https://www.youtube.com/playlist?list=PL123')" '播放列表'

# 正常下载：下到“Mac”，名字是中文，大小对
id=$(add 'https://www.youtube.com/watch?v=okokokokoko' | job_id)
[ -n "$id" ] && ok add || bad add
js=$(wait_job "$id")
has 'done' "$js" '"state":"done"'
has has-file "$js" '"has_file":true'
has stays "$js" '已留在 VPS'
has not-pushed "$js" '"delivered":false'
(cd "$T/mac" && $C -b "$J" -D "$T/headers" -OJ "$B/dl/$id")
f=$(ls "$T/mac")
# 浏览器认 filename*= 里的中文名；curl 只认 filename=，所以存成英文的备用名。
has cn-name "$(cat "$T/headers")" "filename\*=UTF-8''%E6%B5%8B%E8%AF%95%E8%A7%86%E9%A2%91"
check size "$(wc -c < "$T/mac/$f" | tr -d ' ')" 3145728
check range-416 "$($C -b "$J" -o /dev/null -w '%{http_code}' -r 99999999- "$B/dl/$id")" 416

# 送达以后：网页说收起来，列表里就没有它了
has delivered "$($C -b "$J" "$B/api/jobs")" '已存到你的电脑'
has dismiss "$($C -b "$J" -H 'X-YTW: 1' -d "id=$id" "$B/api/dismiss")" '"ok":true'
if $C -b "$J" "$B/api/jobs" | grep -q "\"id\":\"$id\""; then bad hidden-after-dismiss; else ok hidden-after-dismiss; fi
# 送达以后自动删（文件和任务记录一起删）
n=0
while [ -d "$T/data/jobs/$id" ] && ls "$T/data/jobs/$id"/*.mp4 >/dev/null 2>&1 && [ "$n" -lt 40 ]; do
  sleep 0.5
  n=$((n + 1))
done
if ls "$T/data/jobs/$id"/*.mp4 >/dev/null 2>&1; then bad auto-delete; else ok auto-delete; fi
n=0
while [ -d "$T/data/jobs/$id" ] && [ "$n" -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
if [ -d "$T/data/jobs/$id" ]; then bad auto-delete-record; else ok auto-delete-record; fi
# 还没拿的任务不能被收起来
id3=$(add 'https://www.youtube.com/watch?v=notyetgot01' | job_id)
wait_job "$id3" > /dev/null
has no-dismiss-undelivered "$($C -b "$J" -H 'X-YTW: 1' -d "id=$id3" "$B/api/dismiss")" '还没传完'
has delete-log "$(cat "$T/server.log")" '已送达'

# 断点续传：分两段下，拼起来和一次下完一样
id=$(add 'https://youtu.be/rangerange1' | job_id)
wait_job "$id" > /dev/null
$C -b "$J" -r 0-99999 -o "$T/p1" "$B/dl/$id"
$C -b "$J" -r 100000- -o "$T/p2" "$B/dl/$id"
$C -b "$J" -o "$T/full" "$B/dl/$id"
cat "$T/p1" "$T/p2" > "$T/joined"
if cmp -s "$T/joined" "$T/full"; then ok range-resume; else bad range-resume; fi

# 被拦：没有 cookies 时，所有办法都试过以后，中文提示上传 cookies
id=$(add 'https://www.youtube.com/watch?v=botbotbotbo' | job_id)
js=$(wait_job "$id")
has blocked "$js" '"state":"error"'
has blocked-hint "$js" 'cookies'
check tried-client "$(grep -c 'player_client=android_vr' "$T/calls.log")" 1

# 年龄限制、视频没了：中文报错
has age "$(wait_job "$(add 'https://www.youtube.com/watch?v=ageageageag' | job_id)")" '年龄'
has gone "$(wait_job "$(add 'https://www.youtube.com/watch?v=gonegonegon' | job_id)")" '删'

# cookies：乱的不收，对的收下并且权限 600
has ck-json "$($C -b "$J" -H 'X-YTW: 1' --data-urlencode 'text=[{"name":"a"}]' "$B/api/cookies")" 'error'
printf '.youtube.com\tTRUE\t/\tTRUE\t2000000000\tSID\tabc\n' > "$T/ck"
has ck-ok "$($C -b "$J" -H 'X-YTW: 1' --data-urlencode "text@$T/ck" "$B/api/cookies")" '"ok":true'
check ck-mode "$(stat -c %a "$T/cookies.txt" 2>/dev/null || stat -f %OLp "$T/cookies.txt")" 600
check ck-header "$(head -n 1 "$T/cookies.txt")" '# Netscape HTTP Cookie File'

# 有了 cookies，被拦的视频能下了，并且记住这个办法
id=$(add 'https://www.youtube.com/watch?v=botbotbotb2' | job_id)
has bot-cookies "$(wait_job "$id")" '"state":"done"'
has sticky "$(cat "$T/data/state/sticky" 2>/dev/null)" 'cookies'

# 画质：480p / 360p / 240p / 144p 都按高度挑 H.264，网页上显示对应的名字
for r in 480 360 240 144; do
  mark=$(wc -l < "$T/calls.log")
  id=$(add "https://www.youtube.com/watch?v=res${r}x${r}x" "p$r" | job_id)
  js=$(wait_job "$id")
  has "q$r-done" "$js" '"state":"done"'
  has "q$r-label" "$js" "\"quality\":\"${r}p\""
  has "q$r-args" "$(sed -n "$((mark + 1)),\$p" "$T/calls.log" | grep "res${r}x" | head -n 1)" "-S vcodec:h264,res:$r,acodec:aac"
  $C -b "$J" -H 'X-YTW: 1' -d "id=$id" "$B/api/delete" > /dev/null
done
# 不认识的画质按推荐的处理
js=$(wait_job "$(add 'https://www.youtube.com/watch?v=qbadqbadqba' p999 | job_id)")
has q-unknown "$js" 'Mac 能直接播放'
# 压缩已经彻底去掉：旧接口没有了，旧参数也不会触发压缩
has no-compress-api "$($C -b "$J" -H 'X-YTW: 1' -d "id=x" "$B/api/compress")" 'not found'
has no-export-api "$($C -b "$J" -H 'X-YTW: 1' -d "id=x" "$B/api/export")" 'not found'
mark=$(wc -l < "$T/calls.log")
id=$($C -b "$J" -H 'X-YTW: 1' --data-urlencode 'url=https://www.youtube.com/watch?v=oldcompress' -d q=mac -d compress=1 -d speed=2 "$B/api/add" | job_id)
js=$(wait_job "$id")
has old-param-done "$js" '"state":"done"'
check old-param-mp4 "$(ls "$T/data/jobs/$id" | grep -c '\.mp4$')" 1
if sed -n "$((mark + 1)),\$p" "$T/calls.log" | grep -q 'libx265\|setpts\|atempo'; then bad old-param-no-compress; else ok old-param-no-compress; fi
$C -b "$J" -H 'X-YTW: 1' -d "id=$id" "$B/api/delete" > /dev/null

# 删任务
id2=$(add 'https://www.youtube.com/watch?v=delete00001' | job_id)
wait_job "$id2" > /dev/null
$C -b "$J" -H 'X-YTW: 1' -d "id=$id2" "$B/api/delete" > /dev/null
if [ -d "$T/data/jobs/$id2" ]; then bad delete-job; else ok delete-job; fi

# ---------- 多平台 ----------
# 抖音分享文字：自动挑出网址，交给插件；不登录拿不到时，中文提示上传抖音 cookies
id=$(add '6.99 复制打开抖音，看看【测试的作品】这是标题 # 话题 https://v.douyin.com/needck01/ 8@5.com :2pm' | job_id)
[ -n "$id" ] && ok douyin-share-text || bad douyin-share-text
has douyin-meta "$(cat "$T/data/jobs/$id/meta")" 'plat=douyin'
has douyin-url "$(cat "$T/data/jobs/$id/meta")" 'url=https://v.douyin.com/needck01/'
js=$(wait_job "$id")
has douyin-error "$js" '抖音'
has douyin-hint "$js" '"hint":"cookies"'
has douyin-plugin "$(cat "$T/calls.log")" 'ytweb:douyin:https://v.douyin.com/needck01/'
has douyin-ipnote "$(cat "$T/data/jobs/$id/log" 2>/dev/null)" '网络：IPv'
# 上传抖音 cookies：YouTube 的 cookies 还在
printf '.douyin.com\tTRUE\t/\tFALSE\t2000000000\tttwid\txyz\n' > "$T/ck2"
has ck-douyin "$($C -b "$J" -H 'X-YTW: 1' --data-urlencode "text@$T/ck2" "$B/api/cookies")" '抖音'
has ck-keep-yt "$(cat "$T/cookies.txt")" 'SID'
js=$($C -b "$J" "$B/api/jobs")
has ck-sites-yt "$js" '"key":"youtube","name":"YouTube"'
has ck-sites-dy "$js" '"key":"douyin","name":"抖音"'
id=$(add 'https://v.douyin.com/needck02/' | job_id)
has douyin-cookies-done "$(wait_job "$id")" '"state":"done"'
has sticky-douyin "$(cat "$T/data/state/sticky-douyin" 2>/dev/null)" 'cookies'
$C -b "$J" -H 'X-YTW: 1' -d 'plat=douyin' "$B/api/cookies/delete" > /dev/null
if grep -q ttwid "$T/cookies.txt"; then bad ck-del-plat; else ok ck-del-plat; fi
has ck-del-keep "$(cat "$T/cookies.txt")" 'SID'

# 小红书图文：三张图打成一个 zip
id=$(add '一口气带你认识各种各样的楼 http://xhslink.cn/o/imgimg01 复制后打开【小红书】查看笔记！' | job_id)
js=$(wait_job "$id")
has xhs-done "$js" '"state":"done"'
has xhs-zip "$js" '.zip"'
has xhs-note "$js" '3 张图片'
$C -b "$J" -o "$T/x.zip" "$B/dl/$id"
if command -v python3 >/dev/null 2>&1; then
  check zip-ok "$(python3 -c 'import sys,zipfile;z=zipfile.ZipFile(sys.argv[1]);print(z.testzip() is None,len(z.namelist()))' "$T/x.zip")" 'True 3'
elif command -v unzip >/dev/null 2>&1; then
  if unzip -tq "$T/x.zip" >/dev/null 2>&1; then ok zip-ok; else bad zip-ok; fi
fi
# 推特：没有视频就去拿图片；纯文字推文给白话提示
id=$(add 'https://x.com/someone/status/1234567890123/photo/1?s=46' | job_id)
has x-url "$(cat "$T/data/jobs/$id/meta")" 'url=https://x.com/someone/status/1234567890123$'
js=$(wait_job "$id")
has x-images "$js" '"state":"done"'
has x-plugin "$(cat "$T/calls.log")" 'ytweb:ximg:https://x.com/someone/status/1234567890123'
has x-text "$(wait_job "$(add 'https://twitter.com/someone/status/999text999' | job_id)")" '没有视频也没有图片'
# B站：追踪参数剥掉，只留 BV 号，交给插件
id=$(add 'https://www.bilibili.com/video/BV1tHaA6qEXL/?trackid=web_pegasus_0.router&spm_id_from=333.1007&vd_source=bb26' | job_id)
has bili-clean "$(cat "$T/data/jobs/$id/meta")" 'url=https://www.bilibili.com/video/BV1tHaA6qEXL/$'
has bili-done "$(wait_job "$id")" '"state":"done"'
has bili-plugin "$(cat "$T/calls.log")" 'ytweb:bili:https://www.bilibili.com/video/BV1tHaA6qEXL/'
# 只有 VP9：转码成 H.264，先告诉你大概要多久
id=$(add 'https://www.tiktok.com/@a/video/vp9vp9vp9?is_from_webapp=1' | job_id)
js=$(wait_job "$id")
has vp9-done "$js" '"state":"done"'
has vp9-mp4 "$js" '"file":"[^"]*\.mp4"'
has vp9-note "$js" 'VP9'
has vp9-x264 "$(cat "$T/calls.log")" 'libx264'
has vp9-estimate "$(cat "$T/data/jobs/$id/log")" '转换格式'
has h264-format "$(grep 'tiktok.com/@a/video/vp9vp9vp9' "$T/calls.log" | head -n 1)" 'vcodec^=avc'
# YouTube 的画质参数没变
has yt-format "$(grep 'okokokokoko' "$T/calls.log" | head -n 1)" '-S vcodec:h264,res,acodec:aac'
if grep 'okokokokoko' "$T/calls.log" | head -n 1 | grep -q 'vcodec^=avc'; then bad yt-format-same; else ok yt-format-same; fi
# 页面是通用说法
has page-generic "$($C -b "$J" "$B/")" '整段分享文字'

# 升级时：安装脚本挂了牌子（里面是活着的进程号），新任务照收但先不开始，网页显示安心的话
st_of() { $C -b "$J" "$B/api/jobs" | perl -ne 'while(/(\{"[^{}]*?"id":"'"$1"'"[^{}]*\})/g){print $1}'; }
echo "$$" > "$T/data/state/upgrading"
sleep 1.5
r=$(add 'https://www.youtube.com/watch?v=upgradewait')
has upg-note "$r" '服务器正在升级'
id=$(printf '%s' "$r" | job_id)
# 每天的 yt-dlp 更新到点了也先不做
sed 's/^last_update=.*/last_update=1/' "$T/data/state/info" > "$T/data/state/info.new" && mv "$T/data/state/info.new" "$T/data/state/info"
nu=$(grep -c '检查 yt-dlp 更新' "$T/server.log")
sleep 2.5
check upg-no-update "$(grep -c '检查 yt-dlp 更新' "$T/server.log")" "$nu"
js=$(st_of "$id")
has upg-queued "$js" '"state":"queued"'
has upg-line "$js" '服务器正在升级，等一会儿会自动开始'
has upg-info "$($C -b "$J" "$B/api/jobs")" '"upgrading":true'
has upg-banner "$($C -b "$J" "$B/")" 'id="upg"'
# 牌子撤了：自动开始
rm -f "$T/data/state/upgrading"
has upg-resume "$(wait_job "$id")" '"state":"done"'
if [ "$(grep -c '检查 yt-dlp 更新' "$T/server.log")" -gt "$nu" ]; then ok upg-update-later; else bad upg-update-later; fi
has upg-info-off "$($C -b "$J" "$B/api/jobs")" '"upgrading":false'
# 安装脚本早就退出了（进程号不在了）：当没有牌子
dead=$(sh -c 'echo $$')
echo "$dead" > "$T/data/state/upgrading"
r=$(add 'https://www.youtube.com/watch?v=staleflag01')
case "$r" in *'服务器正在升级'*) bad upg-stale-note ;; *) ok upg-stale-note ;; esac
has upg-stale-runs "$(wait_job "$(printf '%s' "$r" | job_id)")" '"state":"done"'
rm -f "$T/data/state/upgrading"

# 重启网页服务：下好了还没传到 Mac 的、还在排队的，重启后都还在
idk=$(add 'https://www.youtube.com/watch?v=keepafterrs' | job_id)
has rs-done-before "$(wait_job "$idk")" '"state":"done"'
echo "$$" > "$T/data/state/upgrading"
sleep 1.5
idq=$(add 'https://www.youtube.com/watch?v=queuedacros' | job_id)
kill "$(cat "$T/data/state/server.pid")"
n=0
while curl -s --noproxy 127.0.0.1 -m 2 "$B/health" >/dev/null 2>&1 && [ "$n" -lt 50 ]; do sleep 0.2; n=$((n + 1)); done
rm -f "$T/data/state/upgrading"
FAKE_LOG=$T/calls.log perl "$T/server.pl" "$T/web.conf" >> "$T/server.log" 2>&1 &
spid=$!
n=0
until curl -s --noproxy 127.0.0.1 "$B/health" 2>/dev/null | grep -q 'ytdlp-web ok'; do
  n=$((n + 1))
  [ "$n" -gt 50 ] && { bad rs-restart; break; }
  sleep 0.2
done
js=$(st_of "$idk")
has rs-kept "$js" '"state":"done"'
has rs-kept-file "$js" '"has_file":true'
rm -rf "$T/mac2" && mkdir -p "$T/mac2"
(cd "$T/mac2" && $C -b "$J" -OJ "$B/dl/$idk")
check rs-fetch-size "$(wc -c < "$T/mac2/$(ls "$T/mac2" | head -n 1)" | tr -d ' ')" 3145728
has rs-queued-runs "$(wait_job "$idq")" '"state":"done"'

if [ "$fail" -ne 0 ]; then
  printf '\n有测试没通过。日志：\n' >&2
  cat "$T/server.log" >&2
  exit 1
fi
printf '\n全部通过。\n'
