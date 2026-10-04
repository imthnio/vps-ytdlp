#!/bin/sh
# 把 install.sh 里内嵌的网页服务拿出来，配一个假的 yt-dlp 真跑一遍：
# 登录、贴链接、下载到“Mac”、断点续传、传完自动删、被拦换办法、cookies、中文报错。
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
mkdir -p "$T/mac"
cat > "$T/web.conf" <<EOF
port=$PORT
listen=127.0.0.1
user=admin
pass_hash=$hash
data=$T/data
ytdlp=$PWD/tests/fake-ytdlp.sh
cookies=$T/cookies.txt
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
has page "$($C -b "$J" "$B/")" '保存到 Mac'
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
has done "$js" '"state":"done"'
has has-file "$js" '"has_file":true'
(cd "$T/mac" && $C -b "$J" -D "$T/headers" -OJ "$B/dl/$id")
f=$(ls "$T/mac")
# 浏览器认 filename*= 里的中文名；curl 只认 filename=，所以存成英文的备用名。
has cn-name "$(cat "$T/headers")" "filename\*=UTF-8''%E6%B5%8B%E8%AF%95%E8%A7%86%E9%A2%91"
check size "$(wc -c < "$T/mac/$f" | tr -d ' ')" 3145728
check range-416 "$($C -b "$J" -o /dev/null -w '%{http_code}' -r 99999999- "$B/dl/$id")" 416

# 送达以后自动删
n=0
while [ -d "$T/data/jobs/$id" ] && ls "$T/data/jobs/$id"/*.mp4 >/dev/null 2>&1 && [ "$n" -lt 40 ]; do
  sleep 0.5
  n=$((n + 1))
done
if ls "$T/data/jobs/$id"/*.mp4 >/dev/null 2>&1; then bad auto-delete; else ok auto-delete; fi
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
check ck-mode "$(stat -c %a "$T/cookies.txt")" 600
check ck-header "$(head -n 1 "$T/cookies.txt")" '# Netscape HTTP Cookie File'

# 有了 cookies，被拦的视频能下了，并且记住这个办法
id=$(add 'https://www.youtube.com/watch?v=botbotbotb2' | job_id)
has bot-cookies "$(wait_job "$id")" '"state":"done"'
has sticky "$(cat "$T/data/state/sticky" 2>/dev/null)" 'cookies'

# 删任务
id2=$(add 'https://www.youtube.com/watch?v=delete00001' | job_id)
wait_job "$id2" > /dev/null
$C -b "$J" -H 'X-YTW: 1' -d "id=$id2" "$B/api/delete" > /dev/null
if [ -d "$T/data/jobs/$id2" ]; then bad delete-job; else ok delete-job; fi

if [ "$fail" -ne 0 ]; then
  printf '\n有测试没通过。日志：\n' >&2
  cat "$T/server.log" >&2
  exit 1
fi
printf '\n全部通过。\n'
