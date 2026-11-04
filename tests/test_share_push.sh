#!/bin/sh
# 「上传到文件传输」：真起一个 minishare（文件传输）和一个 ytdlp-web，
# 下好的视频推到 minishare 的分享里，查文件真的进去了、这边的文件删掉了。
# 需要 perl、curl、python3，和 minishare 的 fileshare.py（1.7.0 以上）：
#   MINISHARE_PY=/路径/fileshare.py sh tests/test_share_push.sh
# 默认找 ../wenjianchuanshu/fileshare.py，找不到就跳过。
cd "$(dirname "$0")/.." || exit 1
MS=${MINISHARE_PY:-../wenjianchuanshu/fileshare.py}
for c in perl curl python3; do command -v $c >/dev/null 2>&1 || { echo "没有 $c，跳过"; exit 0; }; done
[ -f "$MS" ] || { echo "没有 minishare 的 fileshare.py（$MS），跳过"; exit 0; }
MS=$(cd "$(dirname "$MS")" && pwd)/$(basename "$MS")

T=$(mktemp -d)
PORT=${TEST_PORT:-18574}
MPORT=${TEST_MPORT:-18575}
B=http://127.0.0.1:$PORT
fail=0
ok() { printf 'ok %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=1; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 got [$2] want [$3]"; fi; }
has() { if printf '%s' "$2" | grep -q -- "$3"; then ok "$1"; else bad "$1: [$2] 里没有 [$3]"; fi; }

# ---- minishare：一个管理员，两个发送分享，一个接收分享 ----
mkdir -p "$T/ms"
SHARE_DATA="$T/ms" python3 - "$MS" <<'PY'
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("fileshare", sys.argv[1])
app = importlib.util.module_from_spec(spec); spec.loader.exec_module(app)
app.init_db(); app.ext_key()
now = int(time.time())
with app.db() as c:
    c.execute("INSERT INTO users(id,pw,is_admin,created,remark) VALUES(1,'x',1,?,'我')", (now,))
    for sid, typ, title in (("wall0001", "send", "动态壁纸"), ("eng00001", "send", "英语学习资料"),
                            ("recv0001", "receive", "收件箱")):
        c.execute("INSERT INTO shares(id,type,title,created,expires,owner_id) VALUES(?,?,?,?,0,1)",
                  (sid, typ, title, now))
PY
SHARE_DATA="$T/ms" SHARE_HOST=127.0.0.1 SHARE_PORT=$MPORT python3 "$MS" > "$T/ms.log" 2>&1 &
mpid=$!

sed -n "/<<'YTDLP_WEB_SERVER_EOF'$/,/^YTDLP_WEB_SERVER_EOF$/p" install.sh | sed '1d;$d' > "$T/server.pl"
hash=$(perl -e 'print crypt("testpass1", "\$1\$testsalt\$")')
cat > "$T/web.conf" <<EOF
port=$PORT
listen=127.0.0.1
user=admin
pass_hash=$hash
data=$T/data
ytdlp=$PWD/tests/fake-ytdlp.sh
cookies=$T/cookies.txt
grace=2
sweep_secs=2
min_free_mb=10
share_url=http://127.0.0.1:$MPORT
share_key=$(cat "$T/ms/ext-key")
EOF
perl "$T/server.pl" "$T/web.conf" >> "$T/server.log" 2>&1 &
spid=$!
cleanup() {
  kill "$(cat "$T/data/state/server.pid" 2>/dev/null || echo "$spid")" "$mpid" 2>/dev/null
  sleep 1
  rm -rf "$T"
}
trap cleanup EXIT INT TERM

C="curl -s --noproxy 127.0.0.1 -m 30"
i=0
until $C "$B/health" 2>/dev/null | grep -q 'ytdlp-web ok' && $C "http://127.0.0.1:$MPORT/healthz" | grep -q '"ok": true'; do
  i=$((i + 1))
  [ "$i" -gt 50 ] && { cat "$T/server.log" "$T/ms.log"; bad "没启动"; exit 1; }
  sleep 0.2
done
ok started

J=$T/jar
# 这里的密码用 MD5 crypt（$1$），macOS 和 Linux 都认
$C -c "$J" -o /dev/null -d 'user=admin&pass=testpass1' "$B/login"
check need-login "$($C -o /dev/null -w '%{http_code}' "$B/api/shares")" 401
has page-faq "$($C -b "$J" "$B/")" '上传到文件传输'
has info-share "$($C -b "$J" "$B/api/jobs")" '"share":true'

shares=$($C -b "$J" "$B/api/shares")
has list-wall "$shares" '动态壁纸'
has list-eng "$shares" '英语学习资料'
if printf '%s' "$shares" | grep -q '收件箱'; then bad list-no-receive; else ok list-no-receive; fi

add() { $C -b "$J" -H 'X-YTW: 1' --data-urlencode "url=$1" -d "q=mac" "$B/api/add"; }
job_id() { sed -n 's/.*"id":"\([0-9a-f]*\)".*/\1/p'; }
job_json() { $C -b "$J" "$B/api/jobs" | perl -ne 'while(/(\{"[^{}]*?"id":"'"$1"'"[^{}]*\})/g){print $1}'; }
wait_for() {  # wait_for 任务 要出现的字
  n=0
  while [ "$n" -lt 100 ]; do
    js=$(job_json "$1")
    case "$js" in *"$2"*) printf '%s' "$js"; return 0 ;; esac
    n=$((n + 1)); sleep 0.3
  done
  printf '%s' "$js"
}
push() { $C -b "$J" -H 'X-YTW: 1' -d "id=$1" -d "share=$2" --data-urlencode "title=$3" "$B/api/push"; }

id=$(add 'https://www.youtube.com/watch?v=pushpushpus' | job_id)
has done "$(wait_for "$id" '"state":"done"')" '"has_file":true'
src=$(ls "$T/data/jobs/$id/"*.mp4)
sum=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$src")

# 推到不存在的分享：报错，文件还在
has push-bad-share "$(push "$id" nosuch00 '没这个')" '"ok":true'
has bad-share-err "$(wait_for "$id" '"push_error":"分')" '分享不存在'
[ -f "$src" ] && ok bad-share-keeps-file || bad bad-share-keeps-file
check no-header "$($C -b "$J" -o /dev/null -w '%{http_code}' -d "id=$id&share=wall0001" "$B/api/push")" 403
has push-bad-id "$(push 'zz' wall0001 x)" '没有这个任务'

# 正常推送
has push-ok "$(push "$id" wall0001 '动态壁纸')" '"ok":true'
js=$(wait_for "$id" '"pushed":true')
has pushed "$js" '已上传到文件传输「动态壁纸」'
has pushed-no-file "$js" '"has_file":false'
[ -f "$src" ] && bad local-deleted || ok local-deleted
got=$(SHARE_DATA="$T/ms" python3 - "$MS" <<'PY'
import hashlib, importlib.util, os, sys
spec = importlib.util.spec_from_file_location("fileshare", sys.argv[1])
app = importlib.util.module_from_spec(spec); spec.loader.exec_module(app)
with app.db() as c:
    r = c.execute("SELECT * FROM files WHERE share_id='wall0001'").fetchone()
h = hashlib.sha256(open(os.path.join(app.FILES_DIR, r["stored"]), "rb").read()).hexdigest()
print(r["filename"], r["owner_id"], h)
PY
)
check ms-file "$got" "测试视频：中文 标题.mp4 1 $sum"
has dismiss "$($C -b "$J" -H 'X-YTW: 1' -d "id=$id" "$B/api/dismiss")" '"ok":true'
n=0
while [ -d "$T/data/jobs/$id" ] && [ "$n" -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
[ -d "$T/data/jobs/$id" ] && bad sweep-removes || ok sweep-removes

# 密钥不对：列表给出能看懂的原因，按钮还在但会报错
sed -i.bak 's/^share_key=.*/share_key=0000000000000000000000000000000000000000000000000000000000000000/' "$T/web.conf"
kill "$(cat "$T/data/state/server.pid")"; sleep 1
perl "$T/server.pl" "$T/web.conf" >> "$T/server.log" 2>&1 &
spid=$!
i=0; until $C "$B/health" 2>/dev/null | grep -q 'ytdlp-web ok'; do i=$((i+1)); [ $i -gt 50 ] && break; sleep 0.2; done
has wrong-key "$($C -b "$J" "$B/api/shares")" '密钥对不上'

# 没有 minishare：按钮不出现
sed -i.bak '/^share_/d' "$T/web.conf"
kill "$(cat "$T/data/state/server.pid")"; sleep 1
perl "$T/server.pl" "$T/web.conf" >> "$T/server.log" 2>&1 &
spid=$!
i=0; until $C "$B/health" 2>/dev/null | grep -q 'ytdlp-web ok'; do i=$((i+1)); [ $i -gt 50 ] && break; sleep 0.2; done
if [ -f /etc/init.d/minishare ] || [ -f /etc/systemd/system/minishare.service ]; then
  ok "no-share（本机装了 minishare，跳过）"
else
  has no-share "$($C -b "$J" "$B/api/jobs")" '"share":false'
  has no-share-list "$($C -b "$J" "$B/api/shares")" '没找到文件传输'
fi

if [ "$fail" = 0 ]; then echo "全部通过。"; else echo "有失败，看上面的 FAIL。"; tail -20 "$T/server.log"; exit 1; fi
