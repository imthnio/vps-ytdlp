#!/bin/sh
# 假的 yt-dlp，只给 test_server.sh 用。
# 按链接里的关键字假装：成功、被拦（要 cookies）、年龄限制、视频被删。
for a in "$@"; do
  case "$a" in
    -U) echo "yt-dlp is up to date (fake)"; exit 0 ;;
    --version) echo 2026.08.19; exit 0 ;;
  esac
done
home=; url=; ck=0; prev=
for a in "$@"; do
  case "$prev" in --paths) case "$a" in home:*) home=${a#home:} ;; esac ;; esac
  [ "$a" = --cookies ] && ck=1
  prev=$a
  url=$a
done
[ -n "${FAKE_LOG:-}" ] && echo "$@" >> "$FAKE_LOG"
case "$url" in
  *bot*) if [ "$ck" = 0 ]; then echo "ERROR: [youtube] abc: Sign in to confirm you’re not a bot. Use --cookies"; exit 1; fi ;;
  *age*) echo "ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users."; exit 1 ;;
  *gone*) echo "ERROR: [youtube] abc: Video unavailable. This video has been removed by the uploader"; exit 1 ;;
esac
echo "TITLE 测试视频：中文/标题 \"引号\""
f="$home/测试视频：中文 标题.mp4"
head -c 3145728 /dev/urandom > "$f.part"
for p in 10 50 90; do echo "PROG $((p * 31457)) 3145728 NA 1048576.5 2"; sleep 0.2; done
mv "$f.part" "$f"
echo "POST Merger"
echo "FILE $f"
